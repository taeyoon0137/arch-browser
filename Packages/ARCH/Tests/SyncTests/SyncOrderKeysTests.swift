// Order keys among siblings (docs/sync.md, Record types ▸ `order`, and Mapping the session store to records ▸ Order keys).
import Foundation
import Testing
@testable import Sync

@Suite struct SyncOrderKeysTests {
    private func record(_ type: SyncRecordType, _ name: String, _ fields: [String: SyncValue] = [:], order: Double? = nil) -> SyncRecord {
        var record = SyncRecord(recordType: type, recordName: name, fields: fields, modifiedAt: Date(timeIntervalSinceReferenceDate: 0))
        if let order { record[.order] = .number(order) }
        return record
    }

    private let fourInOrder: [String: Double] = ["a": 1, "b": 2, "c": 3, "d": 4]

    @Test func aMovedSiblingTakesTheMidpointOfItsNewNeighbors() {
        #expect(SyncOrderKeys.keys(for: ["a", "d", "b", "c"], existing: fourInOrder) == [1, 1.5, 2, 3])
        #expect(SyncOrderKeys.keys(for: ["b", "c", "d", "a"], existing: fourInOrder) == [2, 3, 4, 5])
        #expect(SyncOrderKeys.keys(for: ["d", "a", "b", "c"], existing: fourInOrder) == [0, 1, 2, 3])
        #expect(SyncOrderKeys.keys(for: ["a", "b", "c", "d"], existing: fourInOrder) == [1, 2, 3, 4])
    }

    @Test func newSiblingsTakeKeysBetweenOrPastTheirNeighbors() {
        #expect(SyncOrderKeys.keys(for: ["a", "b", "c"], existing: [:]) == [1, 2, 3])
        #expect(SyncOrderKeys.keys(for: ["x", "y", "a", "b"], existing: ["a": 1, "b": 2]) == [-1, 0, 1, 2])
        #expect(SyncOrderKeys.keys(for: ["a", "b", "x", "y"], existing: ["a": 1, "b": 2]) == [1, 2, 3, 4])
        #expect(SyncOrderKeys.keys(for: ["a", "x", "y", "b"], existing: ["a": 1, "b": 4]) == [1, 2, 3, 4])
    }

    @Test func keepsTheKeysOfTheLongestRunAlreadyInOrder() {
        // The siblings with keys 1 to 5 keep them, although the longest stretch of neighbors in order is 3, 4, 5.
        let existing: [String: Double] = ["a": 1, "f": 6, "b": 2, "g": 7, "c": 3, "d": 4, "e": 5]
        #expect(SyncOrderKeys.keys(for: ["a", "f", "b", "g", "c", "d", "e"], existing: existing) == [1, 1.5, 2, 2.5, 3, 4, 5])
    }

    @Test func renumbersOnlyWhenTheMidpointEqualsANeighborsKey() {
        // `c` moves between `a` and `b`, whose keys have no `Double` between them.
        let crowded: [String: Double] = ["a": 1, "b": 1.0.nextUp, "d": 2, "c": 3]
        let midpoint = 1 + (1.0.nextUp - 1) / 2
        #expect(midpoint == 1 || midpoint == 1.0.nextUp)
        #expect(SyncOrderKeys.keys(for: ["a", "c", "b", "d"], existing: crowded) == [1, 2, 3, 4])

        // With room between the neighbors, only the moved sibling changes.
        #expect(SyncOrderKeys.keys(for: ["a", "c", "b", "d"], existing: ["a": 1, "b": 1.5, "d": 2, "c": 3]) == [1, 1.25, 1.5, 2])

        // Equal keys leave no room between them either.
        #expect(SyncOrderKeys.keys(for: ["a", "c", "b", "d"], existing: ["a": 1, "b": 1, "d": 2, "c": 3]) == [1, 2, 3, 4])
    }

    @Test func siblingsWithEqualKeysSortByRecordName() {
        let sorted = SyncOrderKeys.sorted([record(.tab, "b", order: 1), record(.tab, "d"), record(.tab, "a", order: 1), record(.tab, "c", order: 0)])
        #expect(sorted.map(\.recordName) == ["c", "a", "b", "d"])

        // Equal keys in record name order are in order, and in the other order one of the two moves.
        #expect(SyncOrderKeys.keys(for: ["a", "b"], existing: ["a": 1, "b": 1]) == [1, 1])
        let swapped = SyncOrderKeys.keys(for: ["b", "a"], existing: ["a": 1, "b": 1])
        #expect(swapped == [0, 1] || swapped == [1, 2])
    }

    @Test func unusableKeysCountAsMissing() {
        #expect(SyncOrderKeys.keys(for: ["a", "b", "c"], existing: ["a": .nan, "b": 2, "c": .infinity]) == [1, 2, 3])
        #expect(SyncOrderKeys.key(of: record(.tab, "a", order: .infinity)) == nil)
        #expect(SyncOrderKeys.key(of: record(.tab, "a", ["order": .text("1")])) == nil)
        #expect(SyncOrderKeys.key(of: record(.tab, "a", order: 2.5)) == 2.5)
    }

    @Test func eachRecordSortsInItsSiblingList() {
        typealias List = SyncOrderKeys.SiblingList
        let persona: [String: SyncValue] = ["persona": .reference("default")]
        #expect(List(of: record(.persona, "default")) == List(recordType: .persona, parent: nil))
        #expect(List(of: record(.space, "space-1", persona)) == List(recordType: .space, parent: "default"))
        #expect(List(of: record(.favorite, "favorite-1", persona)) == List(recordType: .favorite, parent: "default"))
        #expect(List(of: record(.folder, "folder-1", ["persona": .reference("default"), "space": .reference("space-1")])) == List(recordType: .folder, parent: "space-1"))
        #expect(List(of: record(.folder, "folder-2", ["persona": .reference("default"), "space": .reference("space-1"), "parent": .reference("folder-1")])) == List(recordType: .folder, parent: "folder-1"))
        #expect(List(of: record(.tab, "tab-1", ["persona": .reference("default"), "space": .reference("space-1")])) == List(recordType: .tab, parent: "space-1"))
        #expect(List(of: record(.tab, "tab-2", ["persona": .reference("default"), "space": .reference("space-1"), "folder": .reference("folder-1")])) == List(recordType: .tab, parent: "folder-1"))
        #expect(List(of: record(.setting, "ARCHAppearance", ["value": .text("dark")])) == nil)

        // A folder shows its folders before its tabs, so the two keep separate keys.
        let nestedFolder = record(.folder, "folder-2", ["space": .reference("space-1"), "parent": .reference("folder-1")])
        let tabInFolder = record(.tab, "tab-2", ["space": .reference("space-1"), "folder": .reference("folder-1")])
        #expect(List(of: nestedFolder) != List(of: tabInFolder))
    }
}
