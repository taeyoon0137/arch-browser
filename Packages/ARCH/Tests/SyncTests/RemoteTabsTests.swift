import ARCHEngine
import Browsing
import CloudKit
import Foundation
import Testing
@testable import Sync

@Suite struct RemoteTabsRecordsTests {
    let device = UUID().uuidString
    let other = UUID().uuidString
    let space = UUID()
    let date = Date(timeIntervalSinceReferenceDate: 100_000)

    func state(count: Int = 1, title: String = "Page") -> [OpenTabsSpace] {
        [.init(personaID: Persona.defaultID, spaceID: space, tabs: (0..<count).map {
            RemoteTab(url: URL(string: "https://example.test/\($0)")!, title: title, engine: .webKit, order: $0)
        })]
    }

    @Test func publishingEncryptsOnlyTabMetadataAndKeepsOrdersInsidePayload() throws {
        let row = try #require(RemoteTabsRecords.records(from: state(), deviceID: device, deviceName: "Desk", at: date).first)
        let ck = SyncCloudKitRecords.ckRecord(from: row)
        #expect(Set(ck.allKeys().filter { ck[$0] != nil }) == ["persona", "space", "modifiedAt", "schemaVersion"])
        #expect(Set(ck.encryptedValues.allKeys()) == ["deviceID", "deviceName", "tabs", "fieldModifiedAt"])
        #expect(row.schemaVersion == 4)
        let text = try #require(ck.encryptedValues["tabs"] as? String)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let tabs = try #require(payload["tabs"] as? [[String: Any]])
        #expect(Set(tabs[0].keys) == ["url", "title", "engine", "order"])
        #expect(tabs[0]["order"] as? Int == 0)
        #expect(RemoteTabsRecords.groups(from: [row], excluding: other, at: date).first?.tabs == state()[0].tabs)
    }

    @Test func onlyCompleteChunksOfOneGenerationFormAFolder() throws {
        let rows = RemoteTabsRecords.records(from: state(count: 80, title: String(repeating: "A", count: 4000)), deviceID: device, deviceName: "Desk", at: date)
        #expect(rows.count > 1)
        for row in rows {
            guard case .text(let payload) = row[.tabs] else { Issue.record("Missing payload"); continue }
            #expect(payload.utf8.count <= RemoteTabsRecords.chunkByteLimit)
        }
        #expect(RemoteTabsRecords.groups(from: rows, excluding: other, at: date).first?.tabs.count == 80)
        #expect(RemoteTabsRecords.groups(from: Array(rows.dropLast()), excluding: other, at: date).isEmpty)
        let next = RemoteTabsRecords.records(from: state(count: 80, title: String(repeating: "B", count: 4000)), deviceID: device, deviceName: "Desk", at: date.addingTimeInterval(10))
        #expect(RemoteTabsRecords.groups(from: [next[0]] + Array(rows.dropFirst()), excluding: other, at: date.addingTimeInterval(10)).isEmpty)
    }

    @Test func emptyOwnStaleFutureAndForgedRecordsDoNotDisplay() throws {
        let rows = RemoteTabsRecords.records(from: state(), deviceID: device, deviceName: "Desk", at: date)
        #expect(RemoteTabsRecords.records(from: state(count: 0), deviceID: device, deviceName: "Desk", at: date).isEmpty)
        #expect(RemoteTabsRecords.groups(from: rows, excluding: device, at: date).isEmpty)
        #expect(RemoteTabsRecords.groups(from: rows, excluding: other, at: date.addingTimeInterval(RemoteTabsRecords.lifetime)).isEmpty)
        #expect(!RemoteTabsRecords.groups(from: rows, excluding: other, at: date.addingTimeInterval(RemoteTabsRecords.lifetime - 1)).isEmpty)
        #expect(RemoteTabsRecords.groups(from: rows, excluding: other, at: date.addingTimeInterval(-301)).isEmpty)
        var forged = try #require(rows.first)
        forged[.deviceID] = .text(other)
        #expect(!RemoteTabsRecords.owns(forged, deviceID: other))
        #expect(RemoteTabsRecords.groups(from: [forged], excluding: device, at: date).isEmpty)
    }

    @Test func publishingRejectsCredentialsAndNonWebAddresses() {
        let tabs = ["https://user:secret@example.test", "file:///private/document", "about:blank"].enumerated().map {
            RemoteTab(url: URL(string: $0.element)!, title: "Private", engine: .webKit, order: $0.offset)
        }
        #expect(RemoteTabsRecords.records(from: [.init(personaID: Persona.defaultID, spaceID: space, tabs: tabs)], deviceID: device, deviceName: "Desk", at: date).isEmpty)
    }

    @Test func deletingAnAlreadyAbsentRecordAcknowledgesCleanup() {
        let absent = SyncCloudKitRecords.recordID(named: "absent")
        let refused = SyncCloudKitRecords.recordID(named: "refused")
        let sent = CloudKitSyncEngine.sentChanges(savedRecords: [], deletedRecordIDs: [], failedSaves: [],
                                                  failedDeletes: [absent: CKError(.unknownItem), refused: CKError(.permissionFailure)])
        #expect(sent.deletedRecordNames == ["absent"])
    }

    @Test func sidebarPlannersLeaveRemoteRecordsUntouched() throws {
        let remote = RemoteTabsRecords.records(from: state(), deviceID: device, deviceName: "Desk", at: date)
        let first = try FirstSyncMerge.plan(local: [], server: remote, samePage: { $0 == $1 })
        #expect(first.recordsToApply.isEmpty && first.recordsToUpload.isEmpty)
        let incoming = try IncomingSidebarRecords.plan(records: remote, deleted: [:], foundAt: date, defaultEngine: .webKit)
        #expect(incoming.repairs.isEmpty && incoming.recordsToDelete.isEmpty && incoming.sidebar.spaces.isEmpty)
        #expect(IncomingSidebarRecords.heldOut(server: remote, local: []).isEmpty)
    }
}

@MainActor @Suite struct RemoteTabsControllerTests {
    final class Sidebar: SyncedSidebar {
        var needsFullSidebarSync = false
        var defaultEngine: EngineKind = .webKit
        var sidebarSyncState: SidebarSyncState
        var onSidebarSyncSave: ((SidebarSyncState) -> Void)?
        var onOpenTabsSyncSave: (([OpenTabsSpace]) -> Void)?
        var onShowRemoteTabsChange: ((Bool) -> Void)?
        var remoteTabGroups: [RemoteTabGroup] = []
        var showRemoteTabs = true
        var title = "First"
        var hasTabs = true
        var openTabsSyncState: [OpenTabsSpace] {
            sidebarSyncState.spaces.map {
                OpenTabsSpace(personaID: $0.resolvedPersonaID, spaceID: $0.id, tabs: hasTabs ? [
                    RemoteTab(url: URL(string: "https://example.test")!, title: title, engine: .webKit, order: 0)
                ] : [])
            }
        }
        init() {
            sidebarSyncState = .init(personas: [Persona(id: Persona.defaultID, name: "Default")], spaces: [Space(name: "Personal")], folders: [], favorites: [], pinnedTabs: [])
        }
        func finishSidebarSyncRecovery() {}
        func applySidebarSync(_ state: SidebarSyncState, deletions: SidebarSyncDeletions) { sidebarSyncState = state }
        func applyFirstSidebarSync(_ state: SidebarSyncState, replacements: SidebarSyncReplacements) { sidebarSyncState = state }
        func saveNow() -> Result<Void, Error> {
            onSidebarSyncSave?(sidebarSyncState)
            onOpenTabsSyncSave?(openTabsSyncState)
            return .success(())
        }
    }

    @MainActor final class Fixture {
        let name = UUID().uuidString
        let directory: URL
        let defaults: UserDefaults
        let database = SyncDatabase(containerIdentifier: "test.container", environment: "Development")
        let sidebar = Sidebar()
        var now = Date(timeIntervalSinceReferenceDate: 100_000)
        var engines: [FakeSyncEngine] = []
        var server: [String: CKRecord] = [:]
        var offline = false
        var controller: SyncController!

        init() {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            defaults = UserDefaults(suiteName: name)!
            makeController()
        }
        func makeController() {
            controller = SyncController(sidebar: sidebar, directory: directory, defaults: defaults, notifications: NotificationCenter(),
                check: { [weak self] in self.map { .available($0.database) } ?? .unavailable(.temporarilyUnavailable) },
                factory: FakeSyncEngine.factory { [weak self] engine in
                    guard let self else { return }
                    engines.append(engine)
                    engine.onFetch = { [weak self, weak engine] in
                        guard let self else { return [] }
                        engine?.fetchFailure = offline ? .networkUnavailable : nil
                        return [.fetchedChanges(.init(records: Array(server.values)))]
                    }
                    engine.onSavedBatch = { [weak self] batch in
                        for record in batch.records { self?.server[record.recordID.recordName] = record }
                        for name in batch.deletedRecordNames { self?.server[name] = nil }
                    }
                }, now: { [weak self] in self?.now ?? .distantPast }, remoteDebounce: .milliseconds(50), remoteDeviceName: { "Desk" })
        }
        func start() async throws {
            await controller.setEnabled(true)
            try await engines.last?.sendChanges()
        }
        var remoteRecords: [SyncRecord] { server.values.compactMap(SyncCloudKitRecords.syncRecord(from:)).filter { $0.recordType == .remoteTabs } }
        func waitUntil(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        }
        func clean() async {
            await controller.setEnabled(false)
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func defaultsOnDebouncesLatestSnapshotAndNoOpSavesDoNotDelayIt() async throws {
        let f = Fixture()
        try await f.start()
        #expect(f.controller.showRemoteTabs && f.remoteRecords.isEmpty)
        f.sidebar.title = "Latest"
        try f.sidebar.saveNow().get()
        let deadline = ContinuousClock.now + .seconds(3)
        while f.remoteRecords.isEmpty && ContinuousClock.now < deadline {
            try f.sidebar.saveNow().get()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(f.remoteRecords.count == 1)
        let groups = RemoteTabsRecords.groups(from: f.remoteRecords, excluding: UUID().uuidString, at: f.now)
        #expect(groups.first?.tabs.first?.title == "Latest")
        #expect(f.engines.flatMap(\.batches).flatMap(\.records).filter { $0.recordType == "RemoteTabs" }.count == 1)
        await f.clean()
    }

    @Test func closingAllTabsDeletesOnlyThisMacAndKeepsOtherFolder() async throws {
        let f = Fixture()
        let other = UUID().uuidString
        for row in RemoteTabsRecords.records(from: f.sidebar.openTabsSyncState, deviceID: other, deviceName: "Laptop", at: f.now) {
            f.server[row.recordName] = SyncCloudKitRecords.ckRecord(from: row)
        }
        try await f.start()
        await f.waitUntil { f.remoteRecords.count == 2 }
        #expect(f.sidebar.remoteTabGroups.count == 1 && f.sidebar.remoteTabGroups.first?.deviceName == "Laptop")
        f.sidebar.hasTabs = false
        try f.sidebar.saveNow().get()
        await f.waitUntil { f.remoteRecords.count == 1 }
        #expect(f.remoteRecords.first?[.deviceID] == .text(other))
        await f.clean()
    }

    @Test func switchCancelsDebounceDeletesPublicationAndPersistsLocally() async throws {
        let f = Fixture()
        try await f.start()
        f.controller.setShowRemoteTabs(false)
        try await Task.sleep(for: .milliseconds(80))
        #expect(f.remoteRecords.isEmpty && !f.sidebar.showRemoteTabs)
        f.controller.setShowRemoteTabs(true)
        await f.waitUntil { f.remoteRecords.count == 1 }
        f.sidebar.onShowRemoteTabsChange?(false)
        await f.waitUntil { f.remoteRecords.isEmpty }
        #expect(!f.controller.showRemoteTabs && f.sidebar.remoteTabGroups.isEmpty)
        #expect(f.defaults.object(forKey: SyncController.showRemoteTabsKey) as? Bool == false)
        await f.clean()
    }

    @Test func unchangedTabsRefreshDailyAndOldFoldersExpire() async throws {
        let f = Fixture()
        let other = UUID().uuidString
        for row in RemoteTabsRecords.records(from: f.sidebar.openTabsSyncState, deviceID: other, deviceName: "Laptop", at: f.now) {
            f.server[row.recordName] = SyncCloudKitRecords.ckRecord(from: row)
        }
        try await f.start()
        await f.waitUntil { f.remoteRecords.count == 2 }
        let own = f.defaults.string(forKey: SyncController.remoteDeviceIDKey)!
        let original = try #require(f.remoteRecords.first { $0[.deviceID] == .text(own) })
        f.now.addTimeInterval(RemoteTabsRecords.heartbeatInterval)
        f.controller.refreshRemoteTabsLiveness()
        await f.waitUntil { f.remoteRecords.first { $0[.deviceID] == .text(own) }?.modifiedAt == f.now }
        let refreshed = try #require(f.remoteRecords.first { $0[.deviceID] == .text(own) })
        #expect(refreshed.fields == original.fields && refreshed.modifiedAt > original.modifiedAt)
        f.now.addTimeInterval(RemoteTabsRecords.lifetime)
        f.controller.refreshRemoteTabsLiveness()
        #expect(f.sidebar.remoteTabGroups.isEmpty)
        await f.clean()
    }

    @Test func debounceExpiringDuringFailedFetchSendsWhenFetchCompletes() async throws {
        let f = Fixture()
        try await f.start()
        await f.waitUntil { f.remoteRecords.count == 1 }
        f.offline = true
        await f.controller.refresh()
        f.sidebar.title = "After the fetch"
        try f.sidebar.saveNow().get()
        try await Task.sleep(for: .milliseconds(80))
        #expect(RemoteTabsRecords.groups(from: f.remoteRecords, excluding: UUID().uuidString, at: f.now).first?.tabs.first?.title == "First")
        f.offline = false
        await f.controller.refresh()
        await f.waitUntil {
            RemoteTabsRecords.groups(from: f.remoteRecords, excluding: UUID().uuidString, at: f.now).first?.tabs.first?.title == "After the fetch"
        }
        #expect(RemoteTabsRecords.groups(from: f.remoteRecords, excluding: UUID().uuidString, at: f.now).first?.tabs.first?.title == "After the fetch")
        await f.clean()
    }

    @Test func hidingPendingFirstPublicationQueuesDeletionAndKeepsCleanupIntent() async throws {
        let f = Fixture()
        try await f.start()
        let engine = try #require(f.engines.first)
        var hid = false
        engine.beforeRecord = { name in
            guard name.hasPrefix("remote-tabs-"), !hid else { return }
            hid = true
            f.controller.setShowRemoteTabs(false)
            #expect(f.defaults.bool(forKey: SyncController.remoteCleanupKey))
        }
        await f.waitUntil { hid && engine.batches.contains { !$0.deletedRecordNames.isEmpty } }
        #expect(hid && engine.batches.contains { !$0.deletedRecordNames.isEmpty })
        #expect(f.remoteRecords.isEmpty)
        await f.clean()
    }

    @Test func switchRemainsConsistentWhileZoneDeletionWaits() async throws {
        let f = Fixture()
        try await f.start()
        let engine = try #require(f.engines.first)
        engine.zoneFailure = .networkUnavailable
        await f.controller.deleteCloudData()
        #expect(f.controller.isDeletingCloudData)
        f.sidebar.showRemoteTabs = false
        f.sidebar.onShowRemoteTabsChange?(false)
        #expect(!f.controller.showRemoteTabs && !f.sidebar.showRemoteTabs)
        #expect(f.defaults.object(forKey: SyncController.showRemoteTabsKey) as? Bool == false)
        engine.zoneFailure = .permissionFailure
        await f.controller.refresh()
        #expect(!f.controller.showRemoteTabs && !f.sidebar.showRemoteTabs)
        await f.clean()
    }

    @Test func stoppingSyncRemovesOwnRecordsAndOfflineCleanupRetriesAfterRelaunch() async throws {
        let f = Fixture()
        try await f.start()
        await f.waitUntil { f.remoteRecords.count == 1 }
        let sidebarBefore = f.sidebar.sidebarSyncState
        f.offline = true
        await f.controller.setEnabled(false)
        #expect(!f.controller.isEnabled && f.defaults.bool(forKey: SyncController.remoteCleanupKey))
        #expect(f.remoteRecords.count == 1)
        f.makeController()
        f.offline = false
        await f.controller.refreshIfRequested()
        #expect(f.remoteRecords.isEmpty && !f.defaults.bool(forKey: SyncController.remoteCleanupKey))
        #expect(f.sidebar.sidebarSyncState == sidebarBefore)
        let cleanup = try #require(f.engines.last)
        #expect(cleanup.batches.allSatisfy { $0.records.isEmpty })
        #expect(cleanup.isStopped)
        await f.clean()
    }
}
