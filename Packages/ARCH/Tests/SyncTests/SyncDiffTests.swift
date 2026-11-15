// Pending saves and deletions from the local records and the mirror (docs/sync.md, Mapping the session store to records ▸ Outgoing changes and Order keys).
import Foundation
import Testing
@testable import Sync

@Suite struct SyncDiffTests {
    /// The sidebar comparison's scope: every record of the sidebar's types.
    private func inSidebar(_ record: SyncRecord) -> Bool {
        [.persona, .space, .folder, .favorite, .tab].contains(record.recordType)
    }

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
        let unchanged = SyncDiff.changes(local: tabs, scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))
        #expect(unchanged == SyncChanges())

        // `d` moves between `a` and `b`.
        let moved = SyncDiff.changes(local: [tabs[0], tabs[3], tabs[1], tabs[2]], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))
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

        let roomy = SyncDiff.changes(local: movedOrder, scope: inSidebar, mirror: mirror(b: 2), pending: [], foundAt: date(100))
        #expect(roomy.saves.map(\.recordName) == ["e"])
        #expect(roomy.saves.first?[.order] == .number(1.5))

        // Renumbered 1 to 5, the siblings whose keys stay the same need no save.
        let crowded = SyncDiff.changes(local: movedOrder, scope: inSidebar, mirror: mirror(b: 1.0.nextUp), pending: [], foundAt: date(100))
        #expect(crowded.saves.map(\.recordName) == ["e", "b"])
        #expect(crowded.saves.map { $0[.order] } == [.number(2), .number(3)])
        #expect(crowded.saves.allSatisfy { $0.fieldModifiedAt["order"] == date(100) })
    }

    @Test func aTabMovedTwiceBeforeSendingIsOneSaveWithTheSecondMovesTime() {
        let tabs = ["a", "b", "c", "d"].map { tab($0, url: "https://\($0).example/") }
        let mirror = tabs.enumerated().map { mirrored($1, order: Double($0 + 1), at: 10) }
        // `d` moves between `a` and `b`, then on between `b` and `c` before the first move is sent.
        let first = SyncDiff.changes(local: [tabs[0], tabs[3], tabs[1], tabs[2]], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))
        #expect(first.saves.map { $0[.order] } == [.number(1.5)])
        let second = SyncDiff.changes(local: [tabs[0], tabs[1], tabs[3], tabs[2]], scope: inSidebar, mirror: mirror, pending: first.saves, foundAt: date(200))
        #expect(second.saves.map(\.recordName) == ["d"])
        #expect(second.saves.first?[.order] == .number(2.5))
        #expect(second.saves.first?.fieldModifiedAt["order"] == date(200))
        #expect(second.saves.first?.modifiedAt == date(200))

        // When `c` moves to the front instead, `d` keeps the first move's key and time.
        let other = SyncDiff.changes(local: [tabs[2], tabs[0], tabs[3], tabs[1]], scope: inSidebar, mirror: mirror, pending: first.saves, foundAt: date(200))
        #expect(other.saves.map(\.recordName) == ["c", "d"])
        #expect(other.saves.map { $0[.order] } == [.number(0), .number(1.5)])
        #expect(other.saves.map { $0.fieldModifiedAt["order"] } == [date(200), date(100)])
    }

    @Test func aRenamedSpaceGivesOneSaveAndUnchangedStateNone() {
        let defaultPersona = local(.persona, "default", ["name": .text("Personal")])
        let work = space("space-1", title: "Work")
        let home = space("space-2", title: "Home")
        let mirror = [mirrored(defaultPersona, order: 1, at: 10), mirrored(work, order: 1, at: 10), mirrored(home, order: 2, at: 10)]

        let unchanged = SyncDiff.changes(local: [defaultPersona, work, home], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))
        #expect(unchanged.saves.isEmpty)
        #expect(unchanged.deletions.isEmpty)

        let renamed = SyncDiff.changes(local: [defaultPersona, space("space-1", title: "Office"), home], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))
        #expect(renamed.deletions.isEmpty)
        #expect(renamed.saves.count == 1)
        #expect(renamed.saves.first?.recordName == "space-1")
        #expect(renamed.saves.first?.fields == ["persona": .reference("default"), "name": .text("Office"), "tint": .text("blue"), "order": .number(1)])
        #expect(renamed.saves.first?.fieldModifiedAt == ["persona": date(10), "name": date(100), "tint": date(10), "order": date(10)])
        #expect(renamed.saves.first?.modifiedAt == date(100))
    }

    @Test func aPendingRenameKeepsItsTimeWhenTheTintChangesLater() {
        let mirror = [mirrored(space("space-1", title: "Work"), order: 1, at: 10)]
        let renamed = SyncDiff.changes(local: [space("space-1", title: "Office")], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))

        let tinted = SyncDiff.changes(local: [space("space-1", title: "Office", tint: "green")], scope: inSidebar, mirror: mirror, pending: renamed.saves, foundAt: date(200))
        #expect(tinted.saves.count == 1)
        #expect(tinted.saves.first?.fieldModifiedAt == ["persona": date(10), "name": date(100), "tint": date(200), "order": date(10)])
        #expect(tinted.saves.first?.modifiedAt == date(200))

        // A later comparison that finds nothing new keeps every time.
        let again = SyncDiff.changes(local: [space("space-1", title: "Office", tint: "green")], scope: inSidebar, mirror: mirror, pending: tinted.saves, foundAt: date(300))
        #expect(again == tinted)
    }

    @Test func aPendingTimeNoLaterThanTheMirrorsCountsAsANewEdit() {
        // The rename at 100 copies the tint's mirror time, 10, into the pending save.
        let mirror = [mirrored(space("space-1", title: "Work"), order: 1, at: 10)]
        let renamed = SyncDiff.changes(local: [space("space-1", title: "Office")], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))

        // A fetch brings another Mac's green tint from 150, and this Mac picks blue again at 200 before a comparison updates the pending save.
        var fetched = mirror[0]
        fetched[.tint] = .text("green")
        fetched.fieldModifiedAt["tint"] = date(150)
        fetched.modifiedAt = date(150)
        let tinted = SyncDiff.changes(local: [space("space-1", title: "Office")], scope: inSidebar, mirror: [fetched], pending: renamed.saves, foundAt: date(200))
        #expect(tinted.saves.count == 1)
        #expect(tinted.saves.first?[.tint] == .text("blue"))
        #expect(tinted.saves.first?.fieldModifiedAt["tint"] == date(200))
        #expect(tinted.saves.first?.fieldModifiedAt["name"] == date(100))
        #expect(tinted.saves.first?.modifiedAt == date(200))
    }

    @Test func aRecordThatChangesAgainBeforeSendingStaysOneSave() {
        let mirror = [mirrored(space("space-1", title: "Work"), order: 1, at: 10)]
        let first = SyncDiff.changes(local: [space("space-1", title: "Office")], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))
        let second = SyncDiff.changes(local: [space("space-1", title: "Studio")], scope: inSidebar, mirror: mirror, pending: first.saves, foundAt: date(200))
        #expect(second.saves.count == 1)
        #expect(second.saves.first?[.name] == .text("Studio"))
        #expect(second.saves.first?.fieldModifiedAt["name"] == date(200))

        // Renamed back before it is sent, the space needs no save.
        let reverted = SyncDiff.changes(local: [space("space-1", title: "Work")], scope: inSidebar, mirror: mirror, pending: second.saves, foundAt: date(300))
        #expect(reverted == SyncChanges())

        // A record name listed twice counts once.
        let twice = SyncDiff.changes(local: [space("space-1", title: "Office"), space("space-1", title: "Studio")], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))
        #expect(twice.saves.map { $0[.name] } == [.text("Office")])
    }

    @Test func anEditFoundAfterSyncWasOffUsesTheTimeItIsFound() {
        // The rename was found at 100 and not sent; the tint changed while sync was off, and sync turns on again at 500.
        let mirror = [mirrored(space("space-1", title: "Work"), order: 1, at: 10)]
        let pending = SyncDiff.changes(local: [space("space-1", title: "Office")], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100)).saves
        let resumed = SyncDiff.changes(local: [space("space-1", title: "Office", tint: "green")], scope: inSidebar, mirror: mirror, pending: pending, foundAt: date(500))
        #expect(resumed.saves.first?.fieldModifiedAt["name"] == date(100))
        #expect(resumed.saves.first?.fieldModifiedAt["tint"] == date(500))
    }

    @Test func anItemGoneLocallyGivesOneDeletion() {
        let news = local(.favorite, "favorite-1", ["persona": .reference("default"), "url": .text("https://news.example/"), "title": .text("News")])
        let mail = local(.favorite, "favorite-2", ["persona": .reference("default"), "url": .text("https://mail.example/"), "title": .text("Mail")])
        let appearance = SyncRecord(recordType: .setting, recordName: "ARCHAppearance", fields: ["value": .text("dark")], fieldModifiedAt: ["value": date(10)], modifiedAt: date(10))
        let mirror = [mirrored(news, order: 1, at: 10), mirrored(mail, order: 2, at: 10), appearance]

        let gone = SyncDiff.changes(local: [mail], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))
        #expect(gone.saves.isEmpty)
        #expect(gone.deletions == ["favorite-1"])

        // The settings compare apart, so the sidebar's comparison never deletes one, and the reverse.
        let settings = SyncDiff.changes(local: [appearance], scope: { $0.recordType == .setting }, mirror: mirror, pending: [], foundAt: date(100))
        #expect(settings == SyncChanges())
    }

    @Test func settingsOutsideTheScopeAreNeitherSavedNorDeleted() {
        // `ARCHNotListedSetting` stands for a key that only a newer build lists, and `ARCHSearchEngine` for a listed key whose mirror value this build refuses, so its local value stays out of the comparison.
        func setting(_ key: String, _ value: String) -> SyncRecord {
            SyncRecord(recordType: .setting, recordName: key, fields: ["value": .text(value)], fieldModifiedAt: ["value": date(10)], modifiedAt: date(10))
        }
        let mirror = [setting("ARCHAppearance", "dark"), setting("ARCHNotListedSetting", "12"), setting("ARCHSearchEngine", "newer-engine")]
        let compared: Set<String> = ["ARCHAppearance"]
        let appearance = local(.setting, "ARCHAppearance", ["value": .text("light")])

        let changes = SyncDiff.changes(local: [appearance], scope: { $0.recordType == .setting && compared.contains($0.recordName) }, mirror: mirror, pending: [], foundAt: date(100))
        #expect(changes.saves.map(\.recordName) == ["ARCHAppearance"])
        #expect(changes.deletions.isEmpty)

        // A scope of every setting would delete both.
        let everySetting = SyncDiff.changes(local: [appearance], scope: { $0.recordType == .setting }, mirror: mirror, pending: [], foundAt: date(100))
        #expect(everySetting.deletions == ["ARCHNotListedSetting", "ARCHSearchEngine"])
    }

    @Test func aNewItemTakesTheTimeItIsFoundAndAKeyAfterItsSiblings() {
        let mirror = [mirrored(tab("a", url: "https://a.example/"), order: 1, at: 10)]
        let pinned = SyncDiff.changes(local: [tab("a", url: "https://a.example/"), tab("b", url: "https://b.example/")], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))
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
        let moved = SyncDiff.changes(local: [outside, tab("b", url: "https://b.example/")], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))
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
        let intoFolder = SyncDiff.changes(local: [tabs[0], tabs[2], tab("b", url: "https://b.example/", folder: "folder-1")], scope: inSidebar, mirror: mirror, pending: [], foundAt: date(100))
        #expect(intoFolder.saves.map(\.recordName) == ["b"])
        let back = SyncDiff.changes(local: tabs, scope: inSidebar, mirror: mirror, pending: intoFolder.saves, foundAt: date(200))
        #expect(back == SyncChanges())
    }

    @Test func fieldsUnknownToThisBuildKeepTheMirrorsValues() {
        // `futureField` stands for a field that a newer build writes on folders (docs/sync.md, Schema versions).
        let folder = local(.folder, "folder-1", ["persona": .reference("default"), "space": .reference("space-1"), "name": .text("News")])
        var mirrorFolder = mirrored(folder, order: 1, at: 10)
        mirrorFolder.fields["futureField"] = .text("feed-1")
        mirrorFolder.fieldModifiedAt["futureField"] = date(20)
        mirrorFolder.modifiedAt = date(20)
        mirrorFolder.schemaVersion = 2

        let unchanged = SyncDiff.changes(local: [folder], scope: inSidebar, mirror: [mirrorFolder], pending: [], foundAt: date(100))
        #expect(unchanged == SyncChanges())

        var renamed = folder
        renamed[.name] = .text("Reading")
        renamed.fields["futureField"] = .text("feed-2")
        let save = SyncDiff.changes(local: [renamed], scope: inSidebar, mirror: [mirrorFolder], pending: [], foundAt: date(100)).saves.first
        #expect(save?.fields["futureField"] == .text("feed-1"))
        #expect(save?.fieldModifiedAt["futureField"] == date(20))
        #expect(save?[.name] == .text("Reading"))
        #expect(save?.schemaVersion == 2)
    }
}
