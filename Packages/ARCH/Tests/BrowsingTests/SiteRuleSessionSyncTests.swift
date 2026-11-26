import ARCHEngine
@testable import Browsing
import Foundation
import Testing

@MainActor @Suite struct SiteRuleSessionSyncTests {
    private func session(in directory: URL) throws -> BrowserSession {
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        return try BrowserSession(testRegistry: registry, directory: directory)
    }

    private func state(_ session: BrowserSession, spaces: [Space]? = nil, rules: [SiteRule]) -> SidebarSyncState {
        let current = session.sidebarSyncState
        return SidebarSyncState(personas: current.personas, spaces: spaces ?? current.spaces, folders: current.folders,
            favorites: current.favorites, pinnedTabs: current.pinnedTabs, siteRules: rules)
    }

    @Test func incomingRulesSaveBeforeTheSessionCheckpointAndLocalRulesSurviveOmission() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try session(in: directory)
        let space = try #require(session.spaces.first)
        let local = SiteRule(host: "local.example.test", spaceID: space.id, personaID: space.resolvedPersonaID)
        let incoming = SiteRule(host: "remote.example.test", spaceID: space.id, personaID: space.resolvedPersonaID, window: .newWindow)
        try session.siteRules.save(local)
        session.applySidebarSync(state(session, rules: [incoming, incoming]), deletions: SidebarSyncDeletions())
        #expect(Set(SiteRuleStore(directory: directory).rules.map(\.id)) == [local.id, incoming.id])
        try session.saveNow().get()
        var deletions = SidebarSyncDeletions()
        deletions.siteRules.insert(incoming.id)
        session.applySidebarSync(state(session, rules: []), deletions: deletions)
        #expect(SiteRuleStore(directory: directory).rules == [local])
    }

    @Test func firstSyncJoinsRulesAndRemapsTheirSpaceWithoutDuplicatingThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try session(in: directory)
        let oldSpace = try #require(session.spaces.first)
        let newSpace = Space(name: oldSpace.name, personaID: oldSpace.resolvedPersonaID)
        let old = SiteRule(host: "example.test", spaceID: oldSpace.id, personaID: oldSpace.resolvedPersonaID)
        let unmatched = SiteRule(host: "local.example.test", spaceID: oldSpace.id, personaID: oldSpace.resolvedPersonaID)
        let remote = SiteRule(host: old.host, spaceID: newSpace.id, personaID: old.personaID, window: .newWindow)
        try session.siteRules.save(old)
        try session.siteRules.save(unmatched)
        var replacements = SidebarSyncReplacements()
        replacements.spaces[oldSpace.id] = newSpace.id
        replacements.siteRules[old.id] = remote.id
        let incoming = state(session, spaces: [newSpace], rules: [remote])
        session.applyFirstSidebarSync(incoming, replacements: replacements)
        #expect(Set(session.siteRules.rules.map(\.id)) == [remote.id, unmatched.id])
        #expect(session.siteRules.rules.allSatisfy { $0.spaceID == newSpace.id })
        #expect(session.siteRules.rules.first { $0.id == remote.id }?.window == .newWindow)
        try session.saveNow().get()
        #expect(SiteRuleStore(directory: directory).rules == session.siteRules.rules)
        session.applyFirstSidebarSync(incoming, replacements: replacements)
        #expect(session.siteRules.rules.count == 2)
    }

    @Test func failedFirstSyncRuleWriteCannotBeHiddenByTheIdentityCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try session(in: directory)
        let space = try #require(session.spaces.first)
        let rule = SiteRule(host: "example.test", spaceID: space.id, personaID: space.resolvedPersonaID)
        let file = directory.appendingPathComponent("site-rules.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let incoming = state(session, rules: [rule])
        session.applyFirstSidebarSync(incoming, replacements: SidebarSyncReplacements())
        #expect(session.siteRules.rules.isEmpty)
        if case .success = session.saveNow() { Issue.record("The failed rule write allowed the sync checkpoint") }
        try FileManager.default.removeItem(at: file)
        session.applyFirstSidebarSync(incoming, replacements: SidebarSyncReplacements())
        try session.saveNow().get()
        #expect(SiteRuleStore(directory: directory).rules == [rule])
    }

    @Test func aLaterRuleFileStaysUntouchedWhileTheRestOfTheSidebarSyncs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("site-rules.json")
        let future = Data(#"{"version":2,"rules":[],"future":"keep"}"#.utf8)
        try future.write(to: file)
        let session = try session(in: directory)
        var space = try #require(session.spaces.first)
        space.name = "Synced name"
        let rule = SiteRule(host: "example.test", spaceID: space.id, personaID: space.resolvedPersonaID)
        #expect(!session.sidebarSyncState.canSyncSiteRules)
        session.applySidebarSync(state(session, spaces: [space], rules: [rule]), deletions: SidebarSyncDeletions())
        try session.saveNow().get()
        #expect(session.spaces.first?.name == "Synced name" && session.siteRules.rules.isEmpty)
        #expect(try Data(contentsOf: file) == future)
    }

    @Test func successfulSessionSavePublishesTheDurableRuleSet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try session(in: directory)
        let space = try #require(session.spaces.first)
        let rule = SiteRule(host: "example.test", spaceID: space.id, personaID: space.resolvedPersonaID)
        var observed: [SidebarSyncState] = []
        session.onSidebarSyncSave = { observed.append($0) }
        defer { session.onSidebarSyncSave = nil }
        try session.siteRules.save(rule)
        try session.saveNow().get()
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(observed.last?.siteRules == [rule] && observed.last?.canSyncSiteRules == true)
        #expect(SiteRuleStore(directory: directory).rules == observed.last?.siteRules)
    }
}
