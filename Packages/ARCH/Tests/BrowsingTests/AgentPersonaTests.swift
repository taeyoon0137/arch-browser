// The Agents Persona's exception to Persona rule 6 (agent decision 9): its profiles take no remembered permission answers, its requests are denied without a sheet and remembered nowhere, also not in the profile, and a profile of it follows the answers once it becomes an ordinary Persona again. And the one sidebar order that AppleScript's `tabs` and the agents' `list_tabs` read (`BrowserSession.tabsInSidebarOrder`).
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct AgentPersonaTests {
    private static let site = URL(string: "https://example.com/page")!
    private static let origin = "https://example.com"

    @Test func theAgentsPersonaTakesNoRememberedAnswersUntilItIsOrdinary() throws {
        let folder = try Folder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera], origin: Self.origin)
        let answers = SitePermissionAnswers(store: store)
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

    @Test func theAgentsPersonasRequestsAreDeniedWithoutASheetAndNotRemembered() async throws {
        let folder = try Folder()
        let store = SitePermissionStore(directory: folder.url)
        store.set(.allow, for: [.camera], origin: Self.origin)
        let answers = SitePermissionAnswers(store: store)
        let agents = UUID()
        answers.agentOnlyPersonaID = agents
        let profile = KeptAnswers()
        var sheets = 0
        var granted: [Bool] = []
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera, .geolocation]), forTab: UUID(), personaID: agents, in: profile,
                       ask: { _, _ in sheets += 1 }) { granted.append($0) }
        #expect(granted == [false])
        #expect(sheets == 0)
        #expect(store.decision(for: .geolocation, origin: Self.origin) == nil)
        // The profile forgets the denial on the next turn, as Chromium would otherwise keep it.
        try await Task.sleep(for: .milliseconds(50))
        #expect(profile.kept["camera \(Self.site.absoluteString)"] == .some(nil))
        #expect(profile.kept["geolocation \(Self.site.absoluteString)"] == .some(nil))
        // Another Persona's request still takes the remembered answer.
        answers.answer(EnginePermissionRequest(origin: Self.site, types: [.camera]), forTab: UUID(), personaID: Persona.defaultID, in: nil,
                       ask: { _, _ in sheets += 1 }) { granted.append($0) }
        #expect(granted == [false, true])
        #expect(sheets == 0)
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
        firstPinnedInFolder.folderID = pinnedFolder.id
        firstInFolder.folderID = openFolder.id
        let order = BrowserSession.sidebarOrder(favoriteTabs: [favorite], spaces: [first, second], folders: [openFolder, pinnedFolder],
                                                tabs: [secondOpen, small, firstOpen, firstPinned, firstInFolder, firstPinnedInFolder])
        #expect(order.map(\.id) == [favorite, firstPinnedInFolder, firstPinned, firstInFolder, firstOpen, secondOpen, small].map(\.id))
        // A space's own list leaves the small window's tab out, as the sidebar does.
        #expect(BrowserSession.tabs(in: first.id, pinned: false, among: [small, firstOpen, firstInFolder], folders: [openFolder]).map(\.id) == [firstInFolder.id, firstOpen.id])
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
