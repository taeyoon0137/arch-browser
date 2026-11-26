// Remote folders list web addresses; their rows never change tabs on the other Mac.
import ARCHEngine
@testable import Browsing
import Foundation
import Testing

@MainActor @Suite struct RemoteTabsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let page = URL(string: "https://example.test/page")!

    private func temporarySession(_ body: (BrowserSession, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        registry.register(SessionTestEngine(kind: .chromium))
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        try await body(session, directory)
    }

    private func group(in space: Space, name: String = "Desk Mac", date: Date? = nil) -> RemoteTabGroup {
        RemoteTabGroup(deviceID: UUID().uuidString, deviceName: name, personaID: space.resolvedPersonaID, spaceID: space.id,
                       tabs: [RemoteTab(url: page, title: "Page", engine: .chromium, order: 0)], updatedAt: date ?? now)
    }

    @Test func publishesOnlyOpenWebTabsInSidebarOrderWithoutCredentialsOrPageState() async throws {
        try await temporarySession { session, _ in
            let space = try #require(session.spaces.first)
            let outer = session.makeFolder(in: space.id, pinned: false)
            let inner = session.makeFolder(in: space.id, pinned: false, inside: outer.id)
            let outside = session.openTab(url: page, in: space.id, select: false)
            outside.customTitle = "Outside"
            let parent = session.openTab(url: page.appendingPathComponent("parent"), in: space.id, select: false)
            parent.customTitle = "Parent"
            session.moveTab(parent.id, toFolder: outer.id)
            let child = session.openTab(url: URL(string: "https://name:secret@example.test/child")!, in: space.id, select: false, engine: .chromium, state: Data("private state".utf8))
            child.customTitle = "Child"
            session.moveTab(child.id, toFolder: inner.id)
            session.openTab(url: page, in: space.id, pinned: true, select: false)
            session.openTab(url: URL(fileURLWithPath: "/private/local.html"), in: space.id, select: false)
            session.openTab(url: URL(string: "about:blank"), in: space.id, select: false)
            let small = session.openTab(url: page.appendingPathComponent("small"), in: space.id, select: false)
            small.isInSmallWindow = true
            _ = session.openAgentTab(url: page.appendingPathComponent("agent"), engine: .webKit, owner: UUID(), folderName: "Agent", in: space.id)
            let favorite = session.openTab(url: page.appendingPathComponent("favorite"), in: space.id, select: false)
            session.addFavorite(favorite)
            session.toggleCollapsed(ofFolder: outer.id)

            let projected = try #require(session.openTabsSyncState.first { $0.spaceID == space.id })
            #expect(projected.personaID == space.resolvedPersonaID)
            #expect(projected.tabs.map(\.title) == ["Child", "Parent", "Outside"])
            #expect(projected.tabs.map(\.order) == [0, 1, 2])
            #expect(projected.tabs.first?.engine == .chromium)
            #expect(projected.tabs.first?.url == URL(string: "https://example.test/child"))
            let encoded = try JSONEncoder().encode(projected.tabs)
            let values = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
            #expect(values.allSatisfy { Set($0.keys) == ["url", "title", "engine", "order"] })
            #expect(String(decoding: encoded, as: UTF8.self).contains("private state") == false)
        }
    }

    @Test func successfulSavesPublishCapturedOpenTabsAndKeepSidebarObservation() async throws {
        try await temporarySession { session, directory in
            let space = try #require(session.spaces.first)
            let tab = session.openTab(url: page, in: space.id, select: false)
            var sidebarCount = 0
            var observed: [[OpenTabsSpace]] = []
            session.onSidebarSyncSave = { _ in sidebarCount += 1 }
            session.onOpenTabsSyncSave = { observed.append($0) }
            defer {
                session.onSidebarSyncSave = nil
                session.onOpenTabsSyncSave = nil
            }
            tab.customTitle = "Saved"
            try session.saveNow().get()
            tab.customTitle = "Unsaved"
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            #expect(sidebarCount == 1)
            #expect(observed.count == 1 && observed[0].first?.tabs.first?.title == "Saved")

            session.onSidebarSyncSave = nil
            try session.saveNow().get()
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            #expect(sidebarCount == 1 && observed.count == 2)
            #expect(observed.last?.first?.tabs.first?.title == "Unsaved")

            let file = directory.appendingPathComponent("session.json")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try session.saveNow().get() }
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            #expect(observed.count == 2)
        }
    }

    @Test func foldersMatchTheirPersonaAndSpaceAndExpireAtFourteenDays() async throws {
        try await temporarySession { session, _ in
            let space = try #require(session.spaces.first)
            let work = session.addPersona(named: "Work")
            let otherSpace = session.preferredSpace(in: work.id)
            let valid = group(in: space)
            let expiring = group(in: space, name: "Laptop", date: now.addingTimeInterval(-RemoteTabGroup.lifetime + 1))
            let expired = group(in: space, name: "Expired", date: now.addingTimeInterval(-RemoteTabGroup.lifetime))
            var empty = group(in: space)
            empty.tabs = []
            var wrongPersona = group(in: space)
            wrongPersona.personaID = work.id
            var unsupported = group(in: space)
            unsupported.tabs[0].url = URL(fileURLWithPath: "/private/file")
            session.remoteTabGroups = [expired, empty, group(in: otherSpace), wrongPersona, unsupported, expiring, valid]
            session.isSyncing = true

            #expect(session.remoteTabs(in: space, now: now).map(\.deviceName) == ["Desk Mac", "Laptop"])
            #expect(session.remoteTabs(in: space, now: now.addingTimeInterval(1)).map(\.id) == [valid.id])
            #expect(session.remoteTabs(in: otherSpace, now: now).count == 1)
            session.toggleRemoteTabsCollapsed(valid)
            #expect(session.collapsedRemoteTabGroupIDs.contains(valid.id))
            #expect(session.remoteTabGroups.contains(valid))
            session.toggleRemoteTabsCollapsed(valid)
            #expect(!session.collapsedRemoteTabGroupIDs.contains(valid.id))
        }
    }

    @Test func theLocalSwitchDefaultsOnAndReportsOnlyActualChanges() async throws {
        try await temporarySession { session, _ in
            let space = try #require(session.spaces.first)
            session.remoteTabGroups = [group(in: space)]
            var changes: [Bool] = []
            session.onShowRemoteTabsChange = { changes.append($0) }
            #expect(session.showRemoteTabs)
            #expect(session.remoteTabs(in: space, now: now).isEmpty)
            session.isSyncing = true
            #expect(session.remoteTabs(in: space, now: now).count == 1)
            session.showRemoteTabs = false
            session.showRemoteTabs = false
            #expect(changes == [false])
            #expect(session.remoteTabs(in: space, now: now).isEmpty)
            session.showRemoteTabs = true
            #expect(changes == [false, true])
            #expect(session.remoteTabs(in: space, now: now).count == 1)
        }
    }

    @Test func openingARowCreatesANewLocalTabInItsSpaceAndEngineEveryTime() async throws {
        try await temporarySession { session, _ in
            let work = session.addPersona(named: "Work")
            let space = session.preferredSpace(in: work.id)
            let remote = group(in: space)
            session.isSyncing = true
            session.remoteTabGroups = [remote]
            let first = try #require(session.openRemoteTab(remote.tabs[0], from: remote, select: false, now: now))
            let second = try #require(session.openRemoteTab(remote.tabs[0], from: remote, select: false, now: now))
            #expect(first.id != second.id)
            #expect(first.url == page && second.url == page)
            #expect(first.spaceID == space.id && first.personaID == work.id)
            #expect(first.preferredEngine == .chromium && !first.isPinned && first.folderID == nil)
            #expect(session.remoteTabGroups == [remote])
            #expect(session.folders.isEmpty)
            #expect(first.restorableStateForPreferredEngine == nil)
            #expect(session.openRemoteTab(remote.tabs[0], from: remote, select: false, now: now.addingTimeInterval(RemoteTabGroup.lifetime)) == nil)
            session.showRemoteTabs = false
            #expect(session.openRemoteTab(remote.tabs[0], from: remote, select: false, now: now) == nil)
        }
    }

    @Test func remoteRowsSortByPublishedOrderAndCannotOpenAnUnlistedRow() async throws {
        try await temporarySession { session, _ in
            let space = try #require(session.spaces.first)
            var remote = group(in: space)
            remote.tabs = [RemoteTab(url: page, title: "Second", engine: .webKit, order: 1),
                           RemoteTab(url: page, title: "First", engine: .webKit, order: 0)]
            session.isSyncing = true
            session.remoteTabGroups = [remote]
            #expect(remote.orderedTabs.map(\.title) == ["First", "Second"])
            var fabricated = remote.tabs[0]
            fabricated.url = page.appendingPathComponent("unlisted")
            #expect(session.openRemoteTab(fabricated, from: remote, select: false, now: now) == nil)
            #expect(session.tabs.isEmpty)
        }
    }
}
