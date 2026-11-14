// Pending saves and deletions from the local records and the mirror (docs/sync.md, Mapping the session store to records ▸ Outgoing changes and Order keys).
import Foundation
import Testing
@testable import Sync

@Suite struct SyncDiffTests {
    private let sidebarTypes: Set<SyncRecordType> = [.persona, .space, .folder, .favorite, .tab]

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// A record as the local state builds it: fields only, without an order key or edit times.
    private func local(_ type: SyncRecordType, _ name: String, _ fields: [String: SyncValue]) -> SyncRecord {
        SyncRecord(recordType: type, recordName: name, fields: fields, modifiedAt: .distantPast)
    }

    /// A mirror record whose fields were all edited at `seconds`.
    private func mirrored(_ record: SyncRecord, order: Double? = nil, at seconds: TimeInterval) -> SyncRecord {
        var mirrored = record
        if let order { mirrored[.order] = .number(order) }
        mirrored.fieldModifiedAt = mirrored.fields.mapValues { _ in date(seconds) }
        mirrored.modifiedAt = date(seconds)
        return mirrored
    }

    private let persona: [String: SyncValue] = ["persona": .reference("default")]

    private func tab(_ name: String, url: String, folder: String? = nil) -> SyncRecord {
        var fields: [String: SyncValue] = ["persona": .reference("default"), "space": .reference("space-1"), "url": .text(url), "title": .text(name)]
        if let folder { fields["folder"] = .reference(folder) }
        return local(.tab, name, fields)
    }

    private func space(_ name: String, title: String, tint: String = "blue") -> SyncRecord {
        local(.space, name, ["persona": .reference("default"), "name": .text(title), "tint": .text(tint)])
    }

    @Test func movingOnePinnedTabWritesOneRecord() {
        let tabs = ["a", "b", "c", "d"].map { tab($0, url: "https://\($0).example/") }
        let mirror = tabs.enumerated().map { mirrored($1, order: Double($0 + 1), at: 10) }
        let unchanged = SyncDiff.changes(local: tabs, types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100))
        #expect(unchanged == SyncChanges())

        // `d` moves between `a` and `b`.
        let moved = SyncDiff.changes(local: [tabs[0], tabs[3], tabs[1], tabs[2]], types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100))
        #expect(moved.deletions.isEmpty)
        #expect(moved.saves.count == 1)
        let save = moved.saves.first
        #expect(save?.recordName == "d")
        #expect(save?[.order] == .number(1.5))
        #expect(save?.fieldModifiedAt["order"] == date(100))
        #expect(save?.fieldModifiedAt["url"] == date(10))
        #expect(save?.modifiedAt == date(100))
    }

    @Test func renumbersASiblingListOnlyWhenNoKeyFitsBetweenTheNeighbors() {
        let tabs = ["a", "b", "c", "d", "e"].map { tab($0, url: "https://\($0).example/") }
        func mirror(b: Double) -> [SyncRecord] {
            zip(tabs, [1, b, 4, 5, 6]).map { mirrored($0, order: $1, at: 10) }
        }
        // `e` moves between `a` and `b`.
        let movedOrder = [tabs[0], tabs[4], tabs[1], tabs[2], tabs[3]]

        let roomy = SyncDiff.changes(local: movedOrder, types: sidebarTypes, mirror: mirror(b: 2), pending: [], foundAt: date(100))
        #expect(roomy.saves.map(\.recordName) == ["e"])
        #expect(roomy.saves.first?[.order] == .number(1.5))

        // Renumbered 1 to 5, the siblings whose keys stay the same need no save.
        let crowded = SyncDiff.changes(local: movedOrder, types: sidebarTypes, mirror: mirror(b: 1.0.nextUp), pending: [], foundAt: date(100))
        #expect(crowded.saves.map(\.recordName) == ["e", "b"])
        #expect(crowded.saves.map { $0[.order] } == [.number(2), .number(3)])
        #expect(crowded.saves.allSatisfy { $0.fieldModifiedAt["order"] == date(100) })
    }

    @Test func aRenamedSpaceGivesOneSaveAndUnchangedStateNone() {
        let defaultPersona = local(.persona, "default", ["name": .text("Personal")])
        let work = space("space-1", title: "Work")
        let home = space("space-2", title: "Home")
        let mirror = [mirrored(defaultPersona, order: 1, at: 10), mirrored(work, order: 1, at: 10), mirrored(home, order: 2, at: 10)]

        let unchanged = SyncDiff.changes(local: [defaultPersona, work, home], types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100))
        #expect(unchanged.saves.isEmpty)
        #expect(unchanged.deletions.isEmpty)

        let renamed = SyncDiff.changes(local: [defaultPersona, space("space-1", title: "Office"), home], types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100))
        #expect(renamed.deletions.isEmpty)
        #expect(renamed.saves.count == 1)
        #expect(renamed.saves.first?.recordName == "space-1")
        #expect(renamed.saves.first?.fields == ["persona": .reference("default"), "name": .text("Office"), "tint": .text("blue"), "order": .number(1)])
        #expect(renamed.saves.first?.fieldModifiedAt == ["persona": date(10), "name": date(100), "tint": date(10), "order": date(10)])
        #expect(renamed.saves.first?.modifiedAt == date(100))
    }

    @Test func aPendingRenameKeepsItsTimeWhenTheTintChangesLater() {
        let mirror = [mirrored(space("space-1", title: "Work"), order: 1, at: 10)]
        let renamed = SyncDiff.changes(local: [space("space-1", title: "Office")], types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100))

        let tinted = SyncDiff.changes(local: [space("space-1", title: "Office", tint: "green")], types: sidebarTypes, mirror: mirror, pending: renamed.saves, foundAt: date(200))
        #expect(tinted.saves.count == 1)
        #expect(tinted.saves.first?.fieldModifiedAt == ["persona": date(10), "name": date(100), "tint": date(200), "order": date(10)])
        #expect(tinted.saves.first?.modifiedAt == date(200))

        // A later comparison that finds nothing new keeps every time.
        let again = SyncDiff.changes(local: [space("space-1", title: "Office", tint: "green")], types: sidebarTypes, mirror: mirror, pending: tinted.saves, foundAt: date(300))
        #expect(again == tinted)
    }

    @Test func aRecordThatChangesAgainBeforeSendingStaysOneSave() {
        let mirror = [mirrored(space("space-1", title: "Work"), order: 1, at: 10)]
        let first = SyncDiff.changes(local: [space("space-1", title: "Office")], types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100))
        let second = SyncDiff.changes(local: [space("space-1", title: "Studio")], types: sidebarTypes, mirror: mirror, pending: first.saves, foundAt: date(200))
        #expect(second.saves.count == 1)
        #expect(second.saves.first?[.name] == .text("Studio"))
        #expect(second.saves.first?.fieldModifiedAt["name"] == date(200))

        // Renamed back before it is sent, the space needs no save.
        let reverted = SyncDiff.changes(local: [space("space-1", title: "Work")], types: sidebarTypes, mirror: mirror, pending: second.saves, foundAt: date(300))
        #expect(reverted == SyncChanges())

        // A record name listed twice counts once.
        let twice = SyncDiff.changes(local: [space("space-1", title: "Office"), space("space-1", title: "Studio")], types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100))
        #expect(twice.saves.map { $0[.name] } == [.text("Office")])
    }

    @Test func anEditFoundAfterSyncWasOffUsesTheTimeItIsFound() {
        // The rename was found at 100 and not sent; the tint changed while sync was off, and sync turns on again at 500.
        let mirror = [mirrored(space("space-1", title: "Work"), order: 1, at: 10)]
        let pending = SyncDiff.changes(local: [space("space-1", title: "Office")], types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100)).saves
        let resumed = SyncDiff.changes(local: [space("space-1", title: "Office", tint: "green")], types: sidebarTypes, mirror: mirror, pending: pending, foundAt: date(500))
        #expect(resumed.saves.first?.fieldModifiedAt["name"] == date(100))
        #expect(resumed.saves.first?.fieldModifiedAt["tint"] == date(500))
    }

    @Test func anItemGoneLocallyGivesOneDeletion() {
        let news = local(.favorite, "favorite-1", ["persona": .reference("default"), "url": .text("https://news.example/"), "title": .text("News")])
        let mail = local(.favorite, "favorite-2", ["persona": .reference("default"), "url": .text("https://mail.example/"), "title": .text("Mail")])
        let appearance = SyncRecord(recordType: .setting, recordName: "ARCHAppearance", fields: ["value": .text("dark")], fieldModifiedAt: ["value": date(10)], modifiedAt: date(10))
        let mirror = [mirrored(news, order: 1, at: 10), mirrored(mail, order: 2, at: 10), appearance]

        let gone = SyncDiff.changes(local: [mail], types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100))
        #expect(gone.saves.isEmpty)
        #expect(gone.deletions == ["favorite-1"])

        // The settings compare apart, so the sidebar's comparison never deletes one, and the reverse.
        let settings = SyncDiff.changes(local: [appearance], types: [.setting], mirror: mirror, pending: [], foundAt: date(100))
        #expect(settings == SyncChanges())
    }

    @Test func aNewItemTakesTheTimeItIsFoundAndAKeyAfterItsSiblings() {
        let mirror = [mirrored(tab("a", url: "https://a.example/"), order: 1, at: 10)]
        let pinned = SyncDiff.changes(local: [tab("a", url: "https://a.example/"), tab("b", url: "https://b.example/")], types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100))
        #expect(pinned.saves.count == 1)
        let save = pinned.saves.first
        #expect(save?.recordName == "b")
        #expect(save?[.order] == .number(2))
        #expect(save?.fieldModifiedAt == ["persona": date(100), "space": date(100), "url": date(100), "title": date(100), "order": date(100)])
        #expect(save?.modifiedAt == date(100))
        #expect(save?.schemaVersion == SyncRecord.currentSchemaVersion)
    }

    @Test func aTabThatLeavesItsFolderJoinsItsSpacesListWithTheTimeOfTheRemoval() {
        let outside = tab("a", url: "https://a.example/")
        let inFolder = tab("b", url: "https://b.example/", folder: "folder-1")
        let mirror = [mirrored(outside, order: 1, at: 10), mirrored(inFolder, order: 1, at: 10)]
        let moved = SyncDiff.changes(local: [outside, tab("b", url: "https://b.example/")], types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100))
        #expect(moved.saves.count == 1)
        let save = moved.saves.first
        #expect(save?[.folder] == nil)
        #expect(save?[.order] == .number(2))
        #expect(save?.fieldModifiedAt["folder"] == date(100))
        #expect(save?.fieldModifiedAt["order"] == date(100))
        #expect(save?.fieldModifiedAt["space"] == date(10))
    }

    @Test func aTabMovedBackBeforeItIsSentNeedsNoSave() {
        // The pending save is in the folder's list, so the tab takes its key in the space's list from the mirror again.
        let tabs = ["a", "b", "c"].map { tab($0, url: "https://\($0).example/") }
        let mirror = tabs.enumerated().map { mirrored($1, order: Double($0 + 1), at: 10) }
        let intoFolder = SyncDiff.changes(local: [tabs[0], tabs[2], tab("b", url: "https://b.example/", folder: "folder-1")], types: sidebarTypes, mirror: mirror, pending: [], foundAt: date(100))
        #expect(intoFolder.saves.map(\.recordName) == ["b"])
        let back = SyncDiff.changes(local: tabs, types: sidebarTypes, mirror: mirror, pending: intoFolder.saves, foundAt: date(200))
        #expect(back == SyncChanges())
    }

    @Test func fieldsUnknownToThisBuildKeepTheMirrorsValues() {
        // `live` stands for a field that a newer build writes on folders (docs/sync.md, Schema versions).
        let folder = local(.folder, "folder-1", ["persona": .reference("default"), "space": .reference("space-1"), "name": .text("News")])
        var mirrorFolder = mirrored(folder, order: 1, at: 10)
        mirrorFolder.fields["live"] = .text("feed-1")
        mirrorFolder.fieldModifiedAt["live"] = date(20)
        mirrorFolder.modifiedAt = date(20)
        mirrorFolder.schemaVersion = 2

        let unchanged = SyncDiff.changes(local: [folder], types: sidebarTypes, mirror: [mirrorFolder], pending: [], foundAt: date(100))
        #expect(unchanged == SyncChanges())

        var renamed = folder
        renamed[.name] = .text("Reading")
        renamed.fields["live"] = .text("feed-2")
        let save = SyncDiff.changes(local: [renamed], types: sidebarTypes, mirror: [mirrorFolder], pending: [], foundAt: date(100)).saves.first
        #expect(save?.fields["live"] == .text("feed-1"))
        #expect(save?.fieldModifiedAt["live"] == date(20))
        #expect(save?[.name] == .text("Reading"))
        #expect(save?.schemaVersion == 2)
    }
}
