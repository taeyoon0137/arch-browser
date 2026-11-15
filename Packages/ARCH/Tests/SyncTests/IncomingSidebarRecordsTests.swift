import Browsing
import Foundation
import Sync
import Testing

@Suite struct IncomingSidebarRecordsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800)
    private func name(_ index: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", index) }
    private func row(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncValue]) -> SyncRecord {
        SyncRecord(recordType: type, recordName: id, fields: fields, modifiedAt: .distantPast)
    }
    private func persona(_ id: String = "default") -> SyncRecord { row(.persona, id, ["name": .text("Work")]) }
    private func space(_ n: Int, _ owner: String = "default", order: Double = 1) -> SyncRecord {
        row(.space, name(n), ["persona": .reference(owner), "name": .text("Room"), "symbol": .text("star"),
                              "tint": .text("green"), "order": .number(order)])
    }
    private func folder(_ n: Int, _ space: Int, _ parent: Int? = nil, owner: String = "default") -> SyncRecord {
        var item = row(.folder, name(n), ["persona": .reference(owner), "space": .reference(name(space)),
                                          "name": .text("Folder"), "order": .number(Double(n))])
        item[.parent] = parent.map { .reference(name($0)) }
        return item
    }
    private func tab(_ n: Int, _ space: Int, _ folder: Int?, owner: String = "default") -> SyncRecord {
        var item = row(.tab, name(n), ["persona": .reference(owner), "space": .reference(name(space)), "engine": .text("webKit")])
        item[.folder] = folder.map { .reference(name($0)) }
        return item
    }

    @Test func cyclesBreakAtLowestNameAndDeepFoldersFollowTheirParentIntoItsSpace() throws {
        let rows = [persona(), space(1), space(2), folder(10, 1, 12), folder(11, 2, 10), folder(12, 2, 11),
                    folder(13, 2, 12), folder(14, 2, 13), folder(15, 2, 14), tab(20, 2, 15)]
        let plan = try IncomingSidebarRecords.plan(records: rows.reversed(), deleted: [:], foundAt: now, defaultEngine: .webKit)
        let folders = plan.sidebar.folders
        #expect(folders.map(\.id.uuidString) == [10, 11, 12, 13, 14, 15].map(name))
        #expect(folders.map { $0.parentID?.uuidString } == [nil, name(10), name(11), name(12), name(12), name(12)])
        #expect(folders.allSatisfy { $0.spaceID.uuidString == name(1) })
        #expect(plan.sidebar.pinnedTabs.first?.spaceID.uuidString == name(1))
        #expect(plan.repairs.first { $0.recordName == name(14) }?[.order] == .number(14))
        let edits = Dictionary(uniqueKeysWithValues: plan.repairs.map { ($0.recordName, $0) })
        let replay = try IncomingSidebarRecords.plan(records: rows.map { edits[$0.recordName] ?? $0 }, deleted: [:], foundAt: now, defaultEngine: .webKit)
        #expect(replay.repairs.isEmpty && replay.recordsToDelete.isEmpty)
        #expect(replay.sidebar == plan.sidebar)
    }

    @Test func missingOwnersAndCrossPersonaParentsNeverMoveItemsToAnotherPersona() throws {
        let other = name(50)
        let rows = [persona(), persona(other), space(1, order: 9), space(2, order: 1), space(51, other),
                    folder(10, 51, owner: other), folder(11, 51, 10), tab(20, 99, 10), tab(21, 1, nil, owner: name(80))]
        let plan = try IncomingSidebarRecords.plan(records: rows, deleted: [:], foundAt: now, defaultEngine: .webKit)
        let orphan = try #require(plan.sidebar.folders.first { $0.id.uuidString == name(11) })
        #expect(orphan.spaceID.uuidString == name(2) && orphan.parentID == nil)
        let pinned = try #require(plan.sidebar.pinnedTabs.first)
        #expect(pinned.spaceID.uuidString == name(2) && pinned.folderID == nil)
        #expect(plan.recordsToDelete == [name(21)])
    }

    @Test func repeatedSpaceRepairsNameTheSameSpaceAndTombstonesWin() throws {
        let rows = [persona(), space(9), tab(21, 9, nil)]
        let deleted = [name(9): SyncRecordType.space, name(21): .tab]
        let a = try IncomingSidebarRecords.plan(records: rows, deleted: deleted, foundAt: now, defaultEngine: .webKit)
        let b = try IncomingSidebarRecords.plan(records: rows.reversed(), deleted: deleted, foundAt: now.addingTimeInterval(30), defaultEngine: .webKit)
        let personal = try #require(a.sidebar.spaces.first)
        #expect(personal.name == "Personal" && personal.id == b.sidebar.spaces.first?.id)
        #expect(a.repairs.map(\.recordName) == [personal.id.uuidString])
        #expect(a.sidebar.pinnedTabs.isEmpty && a.recordsToDelete.isEmpty)
        #expect(a.deletions.tabs == [UUID(uuidString: name(21))!])
    }

    @Test func fetchedFieldsMergeAgainstTheirBaseAndUnmentionedLocalRowsSurvive() throws {
        let home = space(1)
        var local = home, remote = home
        local[.name] = .text("Edited here")
        remote[.tint] = .text("orange")
        let pin = tab(9, 1, nil)
        let plan = try IncomingSidebarRecords.plan(local: [persona(), local, pin], fetched: [remote],
                                                   mirror: [home], deleted: [:], foundAt: now, defaultEngine: .webKit)
        #expect(plan.sidebar.spaces.first?.name == "Edited here" && plan.sidebar.spaces.first?.tint == .orange)
        #expect(plan.sidebar.pinnedTabs.first?.id.uuidString == name(9))
        #expect(plan.repairs.map(\.recordName) == [name(1)])
    }

    @Test func aServerRecordThatWouldMoveARowToAnotherPersonaWaitsAndTheRestApplies() throws {
        let remote = tab(9, 21, nil, owner: name(20))
        let local = [persona(), persona(name(20)), space(1), space(21, name(20)), tab(9, 1, nil)]
        #expect(IncomingSidebarRecords.heldOut(server: [remote], local: local) == [name(9)])
        let plan = try IncomingSidebarRecords.plan(local: local, fetched: [remote, space(2)], mirror: [], deleted: [:], foundAt: now, defaultEngine: .webKit)
        #expect(plan.sidebar.spaces.map(\.id.uuidString).contains(name(2)))
        #expect(!plan.sidebar.pinnedTabs.contains { $0.id.uuidString == name(9) })
        #expect(plan.repairs.isEmpty && plan.recordsToDelete.isEmpty)
    }

    /// A newer build's values, a feed this Mac would not share, and a home page that is not a web page wait with what they hold, so the fetch applies without them; a tab without an engine takes the default one, and a deletion of another type removes nothing.
    @Test func recordsThisBuildCannotApplyWaitWithTheRecordsUnderThem() throws {
        var newer = space(2)
        newer[.tint] = .text("ultraviolet")
        var home = space(3)
        home[.homeURL] = .text("javascript:alert(1)")
        var unsafe = folder(10, 1)
        unsafe[.live] = .text(#"{"source":{"feed":{"address":"https://example.test/feed?private=value","isPrivate":false}},"itemLimit":10,"refreshMinutes":60}"#)
        var bare = tab(22, 1, nil)
        bare[.engine] = nil
        let rows = [persona(), space(1), newer, home, unsafe, folder(11, 2), tab(20, 2, 11), tab(21, 1, 10), bare]
        #expect(IncomingSidebarRecords.heldOut(server: rows, local: []) == Set([2, 3, 10, 11, 20, 21].map(name)))
        let plan = try IncomingSidebarRecords.plan(records: rows, deleted: [name(1): .tab], foundAt: now, defaultEngine: .chromium)
        #expect(plan.sidebar.spaces.map(\.id.uuidString) == [name(1)] && plan.sidebar.folders.isEmpty)
        #expect(plan.sidebar.pinnedTabs.map(\.id.uuidString) == [name(22)] && plan.sidebar.pinnedTabs.first?.engine == .chromium)
        #expect(plan.repairs.isEmpty && plan.recordsToDelete.isEmpty && plan.deletions.tabs.isEmpty)
    }
}
