// The answers to websites' permission requests: remembered answers decide without a card, each Persona's only in its own tabs and profiles, a file from before Personas kept their own answers gives its answers to every Persona once, a deleted Persona's answers go, requests that wait for one card share its answer, Allow and Don't Allow are remembered and a card that ended without the user is not, engine profiles take the remembered answers and, when they start, the removals of answers, and a website's notifications ask macOS only after the card's Allow and offer System Settings while Arch's notifications are off, as the permission is when the card shows. Each test keeps its store in a temporary folder of its own.
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

    /// Merge Persona Into… moves the source's remembered answers into the target, where the target's own answer for a type stays, and tells the target's profiles; the source keeps none, also after the file is read again.
    @Test func movingAnswersKeepsTheTargetsOwnAndTellsItsProfiles() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let source = UUID(), target = Persona.defaultID
        store.set(.allow, for: [.camera, .microphone], origin: Self.origin, in: source)
        store.set(.deny, for: [.camera], origin: Self.origin, in: target)
        var changes: [(UUID, String, [EnginePermissionType])] = []
        let watching = store.didChange.sink { changes.append(($0.personaID, $0.origin, $0.types)) }
        store.moveAnswers(from: source, to: target)
        watching.cancel()

        let reread = SitePermissionStore(directory: folder.url)
        for current in [store, reread] {
            #expect(current.decision(for: .camera, origin: Self.origin, in: target) == .deny)
            #expect(current.decision(for: .microphone, origin: Self.origin, in: target) == .allow)
            #expect(current.decisions(in: source).isEmpty)
        }
        #expect(changes.count == 1 && changes[0].0 == target && changes[0].2 == [.microphone])
    }

    @Test func rememberedAnswersDecideWithoutACard() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera, .microphone], origin: Self.origin, in: Persona.defaultID)
        store.set(.deny, for: [.geolocation], origin: Self.origin, in: Persona.defaultID)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
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
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
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
        #expect(store.decision(for: .camera, origin: Self.origin, in: Persona.defaultID) == .allow)
        #expect(SitePermissionStore(directory: folder.url).decision(for: .camera, origin: Self.origin, in: Persona.defaultID) == .allow)
    }

    @Test func aCardThatEndedWithoutTheUserAndScreenRecordingLeaveNothingRemembered() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
        let prompts = PromptRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        prompts.respond(.dismissed)
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.screenCapture]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        #expect(prompts.contents.last?.notes.isEmpty == true)
        #expect(prompts.contents.last?.glyph == .symbol("rectangle.dashed.badge.record", tint: .purple, label: "Screen Recording"))
        prompts.respond(Self.allow)

        #expect(granted == [false, true])
        #expect(store.answers.isEmpty)
    }

    @Test func profilesTakeTheRememberedAnswersNowAndAfterEachChange() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera], origin: Self.origin, in: Persona.defaultID)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
        let context = RecordingContext()

        answers.follow(context, of: Persona.defaultID)
        #expect(context.kept["camera \(Self.origin)"] == .some(true))
        store.set(.deny, for: [.microphone], origin: Self.origin, in: Persona.defaultID)
        #expect(context.kept["microphone \(Self.origin)"] == .some(false))
        store.set(nil, for: [.camera], origin: Self.origin, in: Persona.defaultID)
        #expect(context.kept["camera \(Self.origin)"] == .some(nil))

        let other = RecordingContext()
        answers.restoreRememberedAnswers(for: EnginePermissionRequest(origin: Self.site, types: [.camera, .microphone]), personaID: Persona.defaultID, in: other)
        #expect(other.kept["camera \(Self.site.absoluteString)"] == .some(nil))
        #expect(other.kept["microphone \(Self.site.absoluteString)"] == .some(false))
    }

    @Test func eachPersonaKeepsItsOwnAnswersInItsTabsAndProfiles() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let work = UUID()
        store.set(.allow, for: [.camera], origin: Self.origin, in: Persona.defaultID)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
        let prompts = PromptRecorder()

        // The default Persona's Allow answers its tab without a card; the same site asks in Work, which remembers its own answer.
        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera]), forTab: UUID(), personaID: work, in: nil, identity: Self.identity,
                       persona: "the Persona of \u{201C}Work / Research\u{201D}", ask: prompts.ask) { granted.append($0) }
        #expect(prompts.contents.count == 1)
        #expect(prompts.contents.first?.notes.first?.text == "Arch remembers your answer for this website in the Persona of \u{201C}Work / Research\u{201D}. You can change it in Settings \u{25B8} Websites.")
        prompts.respond(Self.deny)
        #expect(granted == [true, false])
        #expect(store.decision(for: .camera, origin: Self.origin, in: work) == .deny)
        #expect(store.decision(for: .camera, origin: Self.origin, in: Persona.defaultID) == .allow)

        // Each profile takes only its Persona's answers, now and after a change.
        let defaultProfile = RecordingContext(), workProfile = RecordingContext()
        answers.follow(defaultProfile, of: Persona.defaultID)
        answers.follow(workProfile, of: work)
        #expect(defaultProfile.kept == ["camera \(Self.origin)": .some(true)])
        #expect(workProfile.kept == ["camera \(Self.origin)": .some(false)])
        store.set(.allow, for: [.geolocation], origin: Self.origin, in: work)
        #expect(workProfile.kept["geolocation \(Self.origin)"] == .some(true))
        #expect(defaultProfile.kept["geolocation \(Self.origin)"] == nil)
        store.set(nil, for: [.camera], origin: Self.origin, in: Persona.defaultID)
        #expect(defaultProfile.kept["camera \(Self.origin)"] == .some(nil))
        #expect(workProfile.kept["camera \(Self.origin)"] == .some(false))
        #expect(SitePermissionStore(directory: folder.url).answers == store.answers)
    }

    /// A `permissions.json` of version 1 held one app-wide set of answers, which every Persona but the Agents Persona takes once; a Persona made later starts empty.
    @Test func appWideAnswersFromAnOlderFileGoToEveryPersonaOnce() throws {
        let folder = try TemporaryFolder()
        let old = #"{"version":1,"sites":{"https://example.com":{"camera":"allow","midi":"deny","future":"allow"}},"removed":{"https://example.com":["geolocation"]}}"#
        try Data(old.utf8).write(to: folder.url.appendingPathComponent("permissions.json"))
        let work = UUID(), agents = UUID()
        let store = SitePermissionStore(directory: folder.url)
        #expect(store.answers.isEmpty)
        store.adoptAppWideAnswers(into: [Persona.defaultID, work])
        for persona in [Persona.defaultID, work] {
            #expect(store.decisions(in: persona) == [Self.origin: [.camera: .allow, .midi: .deny]])
            #expect(store.removed(in: persona) == [Self.origin: [.geolocation]])
        }
        #expect(store.decisions(in: agents).isEmpty)

        // The file now keeps them per Persona, so the next launch copies nothing again, and a later change stays in its Persona.
        store.set(.deny, for: [.camera], origin: Self.origin, in: work)
        let relaunched = SitePermissionStore(directory: folder.url)
        relaunched.adoptAppWideAnswers(into: [Persona.defaultID, work, agents])
        #expect(relaunched.answers == store.answers)
        #expect(relaunched.decision(for: .camera, origin: Self.origin, in: Persona.defaultID) == .allow)
        #expect(relaunched.decisions(in: agents).isEmpty)
    }

    @Test func aDeletedPersonasAnswersGoAtTheLaunchThatRemovesItsData() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let work = UUID()
        store.set(.allow, for: [.camera], origin: Self.origin, in: work)
        store.set(.allow, for: [.camera], origin: Self.origin, in: Persona.defaultID)
        #expect(store.removeAnswers(ofPersona: work))
        #expect(store.removeAnswers(ofPersona: UUID()))
        let relaunched = SitePermissionStore(directory: folder.url)
        #expect(relaunched.decisions(in: work).isEmpty)
        #expect(relaunched.decision(for: .camera, origin: Self.origin, in: Persona.defaultID) == .allow)
    }

    /// The session copies an older file's answers before any profile starts, so the default Persona's profile takes them from launch.
    @Test func theSessionGivesAnOlderFilesAnswersToItsPersonas() throws {
        let folder = try TemporaryFolder()
        try Data(#"{"version":1,"sites":{"https://example.com":{"camera":"allow"}}}"#.utf8).write(to: folder.url.appendingPathComponent("permissions.json"))
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: folder.url)
        #expect(session.sitePermissions.decision(for: .camera, origin: Self.origin, in: Persona.defaultID) == .allow)
        // A new Persona starts without answers.
        let work = session.addPersona(named: "Work")
        #expect(session.sitePermissions.decisions(in: work.id).isEmpty)
        #expect(session.personasWithRememberedAnswers.map(\.id) == [Persona.defaultID, work.id])
    }

    @Test func aProfileThatStartsAfterAnAnswerWasRemovedForgetsItToo() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.geolocation, .camera], origin: Self.origin, in: Persona.defaultID)
        store.set(nil, for: [.geolocation, .camera], origin: Self.origin, in: Persona.defaultID)
        store.set(.deny, for: [.camera], origin: Self.origin, in: Persona.defaultID)
        #expect(store.removed(in: Persona.defaultID) == [Self.origin: [.geolocation]])

        // The next launch reads the removal from the file, and a profile that starts then takes the answer away.
        let relaunched = SitePermissionStore(directory: folder.url)
        #expect(relaunched.removed(in: Persona.defaultID) == [Self.origin: [.geolocation]])
        let answers = SitePermissionAnswers(store: relaunched, notifications: NotificationAuthorization(system: nil))
        let context = RecordingContext()
        answers.follow(context, of: Persona.defaultID)
        #expect(context.kept["geolocation \(Self.origin)"] == .some(nil))
        #expect(context.kept["camera \(Self.origin)"] == .some(false))

        // A new answer takes the type off the list.
        relaunched.set(.allow, for: [.geolocation], origin: Self.origin, in: Persona.defaultID)
        #expect(relaunched.removed(in: Persona.defaultID).isEmpty)
        #expect(context.kept["geolocation \(Self.origin)"] == .some(true))
    }

    @Test func allowingNotificationsAsksMacOSOnceAfterTheCard() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let system = FakeNotificationSystem(status: .notDetermined)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: system.system))
        let prompts = PromptRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        let content = try #require(prompts.show())
        #expect(content.notes.map(\.text) == ["Arch remembers your answer for this website. You can change it in Settings \u{25B8} Websites.", "After you click Allow, macOS asks whether Arch can send you notifications."])
        #expect(content.buttons.map(\.title) == ["Don\u{2019}t Allow", "Allow"])
        #expect(system.requests == 0)

        prompts.respond(Self.allow)
        #expect(granted == [true])
        #expect(system.requests == 1)
        #expect(store.decision(for: .notifications, origin: Self.origin, in: Persona.defaultID) == .allow)

        // The remembered Allow answers without a card and without asking macOS again.
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        #expect(granted == [true, true])
        #expect(prompts.contents.count == 1)
        #expect(system.requests == 1)
    }

    @Test func dontAllowAndOtherPermissionsDoNotAskMacOS() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let system = FakeNotificationSystem(status: .notDetermined)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: system.system))
        let prompts = PromptRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        _ = prompts.show()
        prompts.respond(Self.deny)
        // A card for another permission says nothing about notifications.
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        #expect(prompts.show()?.notes.map(\.id) == ["remembers"])
        prompts.respond(Self.allow)

        #expect(granted == [false, true])
        #expect(system.requests == 0)
        #expect(store.decision(for: .notifications, origin: Self.origin, in: Persona.defaultID) == .deny)
    }

    @Test func whileArchsNotificationsAreOffTheCardOpensSystemSettingsAndRemembersNothing() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let system = FakeNotificationSystem(status: .denied)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: system.system))
        let prompts = PromptRecorder()

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        let content = try #require(prompts.show())
        #expect(content.buttons.map(\.title) == ["Open System Settings", "Don\u{2019}t Allow", "Allow"])
        #expect(content.notes.contains { $0.text.contains("off in System Settings") })
        // Return and Escape keep Allow and Don't Allow, and only Allow waits for the card to arm.
        #expect(PromptKeys.returnButton(in: content) == "allow" && PromptKeys.escapeButton(in: content) == "deny")
        #expect(content.buttons.filter(\.needsArming).map(\.id) == ["allow"])

        prompts.respond(.answered(PromptAnswer(buttonID: "openSystemSettings")))
        #expect(granted == [false])
        #expect(system.opened.count == 1)
        #expect(system.requests == 0)
        #expect(store.answers.isEmpty)

        // A bare build says that it cannot show notifications and offers no setting.
        let bare = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
        bare.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        let bareContent = try #require(prompts.show())
        #expect(bareContent.buttons.map(\.id) == ["deny", "allow"])
        #expect(bareContent.notes.contains { $0.text.contains("can\u{2019}t show notifications") })
    }

    /// A card that waits behind another while macOS's answer changes the permission shows, and acts on, the permission as it is when it shows.
    @Test func aWaitingCardShowsThePermissionAsItIsWhenItShows() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let system = FakeNotificationSystem(status: .notDetermined)
        system.grants = false
        let authorization = NotificationAuthorization(system: system.system)
        let answers = SitePermissionAnswers(store: store, notifications: authorization)
        let prompts = PromptRecorder()
        let other = try #require(URL(string: "https://example.org/"))

        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.notifications]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        answers.answer(EnginePermissionRequest(origin: other, types: [.notifications]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        // Both cards said that macOS asks when they were queued.
        #expect(prompts.contents.allSatisfy { $0.notes.contains { $0.id == "asksMacOS" } })
        #expect(prompts.show()?.notes.contains { $0.id == "asksMacOS" } == true)
        // Allow on the first card asks macOS, and the user refuses there.
        prompts.respond(Self.allow)
        #expect(system.requests == 1)
        #expect(authorization.status == .denied)

        // The second card, made again as it shows, says that Arch's notifications are off, and its Allow does not ask macOS.
        let waiting = try #require(prompts.show())
        #expect(waiting.buttons.map(\.title) == ["Open System Settings", "Don\u{2019}t Allow", "Allow"])
        prompts.respond(Self.allow)
        #expect(granted == [true, true])
        #expect(system.requests == 1)
        #expect(system.opened.isEmpty)
    }

    @Test func theCardAsksUnderTheSiteWithAllowArmedLaterAndEscapeOnDontAllow() throws {
        let folder = try TemporaryFolder()
        let store = SitePermissionStore(directory: folder.url)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
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
        #expect(store.decision(for: .camera, origin: Self.origin, in: Persona.defaultID) == .deny)
        #expect(store.decision(for: .microphone, origin: Self.origin, in: Persona.defaultID) == .deny)

        // A page without a host is "this page", and nothing about it is remembered.
        answers.answer(EnginePermissionRequest(origin: URL(string: "data:text/html,hi")!, types: [.geolocation]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: Self.identity, ask: prompts.ask) { granted.append($0) }
        #expect(prompts.contents.last?.title == "Allow this page to see your location?")
        #expect(prompts.contents.last?.notes.isEmpty == true)
    }
}

/// Stands in for a tab's prompt queue without windows: keeps the cards that the answers asked with, each with the content its maker made when asked, as `BrowserSession.enqueuePrompt(making:for:completion:)` queues it, and shows and answers the oldest one still waiting, making its content again as it shows, as `PromptState.remake()` does when `PanePromptLayer` shows a card.
private final class PromptRecorder {
    private(set) var contents: [PromptContent] = []
    private var waiting: [(makeContent: () -> PromptContent, completion: (PromptResponse) -> Void)] = []

    func ask(_ makeContent: @escaping () -> PromptContent, _ completion: @escaping (PromptResponse) -> Void) {
        contents.append(makeContent())
        waiting.append((makeContent, completion))
    }

    /// The oldest waiting card's content as the maker makes it when the card shows, or nil without one.
    func show() -> PromptContent? {
        waiting.first?.makeContent()
    }

    func respond(_ response: PromptResponse) {
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
