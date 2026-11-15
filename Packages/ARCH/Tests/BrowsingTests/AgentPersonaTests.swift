// The Agents Persona's exception to Persona rule 6 (agent decision 9): its profiles take no remembered permission answers, also when the answers are made with it, as the session makes them before any engine starts, its requests are denied without a card and remembered nowhere, also not in the profile, and a profile of it follows the answers once it becomes an ordinary Persona again. And the one sidebar order that AppleScript's `tabs` and the agents' `list_tabs` read (`BrowserSession.tabsInSidebarOrder`).
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct AgentPersonaTests {
    private static let site = URL(string: "https://example.com/page")!
    private static let origin = "https://example.com"

    @Test func theDraftSummarizesSensitiveWebsiteAnswersForOrdinaryPersonas() throws {
        let folder = try Folder()
        let store = SitePermissionStore(directory: folder.url)
        let agents = UUID(), ordinary = UUID()
        func note(_ persona: UUID) -> String? {
            store.agentPermissionNote(for: persona, agentOnlyPersonaID: agents)
        }
        store.set(.allow, for: [.notifications, .clipboard], origin: Self.origin)
        #expect(note(ordinary) == nil)
        // Agent tabs deny requests themselves, so a denial needs no note.
        store.set(.deny, for: [.microphone], origin: Self.origin)
        #expect(note(ordinary) == nil)
        store.set(.allow, for: [.camera, .microphone, .geolocation], origin: "https://other.example")
        let mixed = try #require(note(ordinary))
        for name in ["Sites you allowed to use the camera", "the microphone", "your location", "keep that access in agent tabs that run in Chromium."] { #expect(mixed.contains(name)) }
        #expect(!mixed.contains("example"))
        #expect(note(Persona.defaultID) == mixed && note(agents) == nil)
        store.set(nil, for: [.camera, .microphone, .geolocation], origin: "https://other.example")
        store.set(nil, for: [.microphone], origin: Self.origin)
        #expect(note(ordinary) == nil)
    }

    @Test func theAgentsPersonaTakesNoRememberedAnswersUntilItIsOrdinary() throws {
        let folder = try Folder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera], origin: Self.origin)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
        let agents = UUID()
        answers.agentOnlyPersonaID = agents
        let agentProfile = KeptAnswers()
        let ordinaryProfile = KeptAnswers()
        answers.follow(agentProfile, of: agents)
        answers.follow(ordinaryProfile, of: Persona.defaultID)
        #expect(agentProfile.kept.isEmpty)
        #expect(ordinaryProfile.kept["camera \(Self.origin)"] == .some(true))
        // A change in Settings reaches only the ordinary profile.
        store.set(.deny, for: [.microphone], origin: Self.origin)
        #expect(agentProfile.kept.isEmpty)
        // Once agent.json no longer names it, its running profile follows the answers.
        answers.agentOnlyPersonaID = nil
        #expect(agentProfile.kept["camera \(Self.origin)"] == .some(true))
        #expect(agentProfile.kept["microphone \(Self.origin)"] == .some(false))
    }

    /// The card and Settings ▸ Websites say that an answer holds in every Persona only while there are several besides the Agents Persona.
    @Test func theAgentsPersonaDoesNotCountAsAPersonaThatSharesAnswers() throws {
        let folder = try Folder()
        let answers = SitePermissionAnswers(store: SitePermissionStore(directory: folder.url), notifications: NotificationAuthorization(system: nil))
        let main = Persona(id: Persona.defaultID, name: "Personal"), agents = Persona(name: "Agents"), work = Persona(name: "Work")
        #expect(answers.holdsInSeveralPersonas([main, agents]))
        answers.agentOnlyPersonaID = agents.id
        #expect(!answers.holdsInSeveralPersonas([main, agents]))
        #expect(answers.holdsInSeveralPersonas([main, agents, work]))
    }

    /// The session makes its answers with the Persona that `agent.json` records, before any engine starts, so the profile that a restored favorite's tab starts while the session is created takes nothing.
    @Test func answersMadeWithTheAgentsPersonaGiveItsFirstProfileNothing() throws {
        let folder = try Folder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera], origin: Self.origin)
        let agents = UUID()
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil), agentOnlyPersonaID: agents)
        #expect(answers.agentOnlyPersonaID == agents)
        let profile = KeptAnswers()
        answers.follow(profile, of: agents)
        store.set(.allow, for: [.microphone], origin: Self.origin)
        #expect(profile.kept.isEmpty)
    }

    @Test func theAgentsPersonasRequestsAreDeniedWithoutACardAndNotRemembered() async throws {
        let folder = try Folder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera], origin: Self.origin)
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil))
        let agents = UUID()
        answers.agentOnlyPersonaID = agents
        let profile = KeptAnswers()
        let identity = PromptIdentity(icon: .symbol("globe"), name: "example.com", isSecure: true)
        var cards = 0
        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera, .geolocation]), forTab: UUID(), personaID: agents, in: profile, identity: identity,
                       ask: { _, _ in cards += 1 }) { granted.append($0) }
        #expect(granted == [false])
        #expect(cards == 0)
        #expect(store.decision(for: .geolocation, origin: Self.origin) == nil)
        // The profile forgets the denial on the next turn, as Chromium would otherwise keep it.
        try await Task.sleep(for: .milliseconds(50))
        #expect(profile.kept["camera \(Self.site.absoluteString)"] == .some(nil))
        #expect(profile.kept["geolocation \(Self.site.absoluteString)"] == .some(nil))
        // Another Persona's request still takes the remembered answer.
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera]), forTab: UUID(), personaID: Persona.defaultID, in: nil, identity: identity,
                       ask: { _, _ in cards += 1 }) { granted.append($0) }
        #expect(granted == [false, true])
        #expect(cards == 0)
    }

    /// The permission card and Settings ▸ Websites say "in every Persona" only while answers reach more than one Persona, and the Agents Persona takes none.
    @Test func theAgentsPersonaDoesNotCountAmongThePersonasThatTakeAnswers() throws {
        let folder = try Folder()
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: folder.url)
        session.agentOnlyPersonaID = session.addPersona(named: "Agents").id
        #expect(!session.remembersAnswersInSeveralPersonas)
        _ = session.addPersona(named: "Work")
        #expect(session.remembersAnswersInSeveralPersonas)
    }

    /// Chromium keeps the denial of an agent tab's request, so the profile's kept answers go back to the remembered ones, or to none in the agent-only Persona.
    @Test func aDenialWithoutAskingLeavesTheKeptAnswersAsRemembered() async throws {
        let folder = try Folder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera], origin: Self.origin)
        let agents = UUID()
        let answers = SitePermissionAnswers(store: store, notifications: NotificationAuthorization(system: nil), agentOnlyPersonaID: agents)
        let request = EnginePermissionRequest(origin: Self.site, types: [.camera, .geolocation])
        let user = KeptAnswers()
        let agentOnly = KeptAnswers()
        var granted: [Bool] = []
        answers.denyWithoutAsking(request, personaID: Persona.defaultID, in: user) { granted.append($0) }
        answers.denyWithoutAsking(request, personaID: agents, in: agentOnly) { granted.append($0) }
        #expect(granted == [false, false])
        try await Task.sleep(for: .milliseconds(50))
        #expect(user.kept["camera \(Self.site.absoluteString)"] == .some(true))
        #expect(user.kept["geolocation \(Self.site.absoluteString)"] == .some(nil))
        #expect(agentOnly.kept["camera \(Self.site.absoluteString)"] == .some(nil))
        #expect(store.decision(for: .geolocation, origin: Self.origin) == nil)
    }

    @Test func appleScriptAndListTabsReadOneSidebarOrder() {
        let personaID = Persona.defaultID
        let first = Space(name: "First", personaID: personaID)
        let second = Space(name: "Second", personaID: personaID)
        func tab(_ space: Space?, pinned: Bool = false) -> Tab {
            Tab(id: UUID(), webContents: UnloadedWebContents(url: URL(string: "https://example.com/\(UUID().uuidString)"), title: "", engine: .webKit, state: nil),
                spaceID: space?.id, isPinned: pinned, personaID: personaID)
        }
        let favorite = tab(nil)
        let secondOpen = tab(second)
        let firstOpen = tab(first)
        let firstPinnedInFolder = tab(first, pinned: true)
        let firstPinned = tab(first, pinned: true)
        let firstInFolder = tab(first)
        let small = tab(first)
        small.isInSmallWindow = true
        let pinnedFolder = TabFolder(spaceID: first.id, name: "Pinned", isPinned: true)
        let openFolder = TabFolder(spaceID: first.id, name: "Open", isPinned: false)
        var nested = TabFolder(spaceID: first.id, name: "Inside", isPinned: false)
        nested.parentID = openFolder.id
        let nestedTab = tab(first)
        nestedTab.folderID = nested.id
        firstPinnedInFolder.folderID = pinnedFolder.id
        firstInFolder.folderID = openFolder.id
        let order = BrowserSession.sidebarOrder(favoriteTabs: [favorite], spaces: [first, second], folders: [openFolder, nested, pinnedFolder],
                                                tabs: [secondOpen, small, firstOpen, firstPinned, firstInFolder, firstPinnedInFolder, nestedTab])
        #expect(order.map(\.id) == [favorite, firstPinnedInFolder, firstPinned, nestedTab, firstInFolder, firstOpen, secondOpen, small].map(\.id))
        // A space's own list leaves the small window's tab out, as the sidebar does.
        let tree = FolderTree(folders: [openFolder, nested], tabs: [small, firstOpen, firstInFolder, nestedTab])
        #expect(tree.tabs(in: first.id, pinned: false).map(\.id) == [nestedTab.id, firstInFolder.id, firstOpen.id])
    }
}

/// A profile that keeps the last answer set for each type and origin.
private final class KeptAnswers: EngineBrowserContext {
    let downloads: any EngineDownloads = Downloads()
    var preferences = EnginePreferences()
    let extensions: (any EngineExtensions)? = nil
    private(set) var kept: [String: Bool?] = [:]

    func setRememberedPermission(_ allowed: Bool?, for type: EnginePermissionType, origin: URL) {
        kept["\(type.rawValue) \(origin.absoluteString)"] = .some(allowed)
    }

    private final class Downloads: EngineDownloads {
        weak var delegate: (any EngineDownloadsDelegate)?
        let items: [any EngineDownloadItem] = []
    }
}

private final class Folder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchAgentPersonaTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
