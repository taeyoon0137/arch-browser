// The per-field merge of this Mac's record with the server's (docs/sync.md, Conflicts and First sync on a Mac; sync decisions 3 and 4).
import Foundation
import Testing
@testable import Sync

@Suite struct SyncMergeTests {
    private func record(type: SyncRecordType = .space, name: String = "space-1", _ fields: [String: SyncValue], times: [String: TimeInterval] = [:], at seconds: TimeInterval, schemaVersion: Int = 1) -> SyncRecord {
        SyncRecord(recordType: type, recordName: name, fields: fields, fieldModifiedAt: times.mapValues(date), modifiedAt: date(seconds), schemaVersion: schemaVersion)
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    private let base: [String: SyncValue] = ["persona": .reference("default"), "name": .text("Work"), "tint": .text("blue"), "order": .number(1)]

    @Test func fieldChangedOnlyHereIsSent() {
        var local = base
        local["name"] = .text("Home")
        let result = SyncMerge.merge(local: record(local, at: 20), server: record(base, at: 10), base: .mirror(record(base, at: 10)))
        #expect(result.needsSend)
        #expect(result.record.fields == local)
        #expect(result.record.modifiedAt == Date(timeIntervalSinceReferenceDate: 20))
    }

    @Test func fieldChangedOnlyOnTheServerNeedsNoSend() {
        var server = base
        server["name"] = .text("Home")
        let serverRecord = record(server, at: 10)
        let result = SyncMerge.merge(local: record(base, at: 30), server: serverRecord, base: .mirror(record(base, at: 5)))
        #expect(!result.needsSend)
        #expect(result.record == serverRecord)
    }

    /// Two records that are not versions of one record keep the server's, with nothing to send, instead of stopping the app on a debug build's assertion.
    @Test(arguments: [(name: "space-2", type: SyncRecordType.space), (name: "space-1", type: .folder)])
    func recordsOfAnotherNameOrTypeDoNotMerge(name: String, type: SyncRecordType) {
        var local = base
        local["name"] = .text("Home")
        let serverRecord = record(base, at: 10)
        let result = SyncMerge.merge(local: record(type: type, name: name, local, at: 20), server: serverRecord, base: .firstWrite)
        #expect(!result.needsSend && result.record == serverRecord)
    }

    @Test func unchangedRecordNeedsNoSend() {
        let serverRecord = record(base, at: 10)
        let result = SyncMerge.merge(local: record(base, at: 10), server: serverRecord, base: .mirror(serverRecord))
        #expect(!result.needsSend)
        #expect(result.record == serverRecord)
    }

    @Test(arguments: [(local: 30.0, server: 20.0), (local: 20.0, server: 30.0)])
    func changesToDifferentFieldsBothSurvive(times: (local: Double, server: Double)) {
        // One Mac renames the space and moves it while the other changes its tint.
        var local = base
        local["name"] = .text("Home")
        local["order"] = .number(1.5)
        var server = base
        server["tint"] = .text("green")
        let result = SyncMerge.merge(local: record(local, at: times.local), server: record(server, at: times.server), base: .mirror(record(base, at: 10)))
        #expect(result.needsSend)
        #expect(result.record.fields == ["persona": .reference("default"), "name": .text("Home"), "tint": .text("green"), "order": .number(1.5)])
        #expect(result.record.modifiedAt == Date(timeIntervalSinceReferenceDate: 30))
    }

    @Test func laterEditWinsAFieldChangedOnBothSides() {
        var local = base
        local["name"] = .text("Home")
        var server = base
        server["name"] = .text("Office")

        let localLater = SyncMerge.merge(local: record(local, at: 30), server: record(server, at: 20), base: .mirror(record(base, at: 10)))
        #expect(localLater.needsSend)
        #expect(localLater.record[.name] == .text("Home"))

        let serverRecord = record(server, at: 30)
        let serverLater = SyncMerge.merge(local: record(local, at: 20), server: serverRecord, base: .mirror(record(base, at: 10)))
        #expect(!serverLater.needsSend)
        #expect(serverLater.record == serverRecord)
    }

    @Test func serverWinsATie() {
        var local = base
        local["name"] = .text("Home")
        var server = base
        server["name"] = .text("Office")
        let serverRecord = record(server, at: 20)
        let result = SyncMerge.merge(local: record(local, at: 20), server: serverRecord, base: .mirror(record(base, at: 10)))
        #expect(!result.needsSend)
        #expect(result.record == serverRecord)
    }

    @Test func sameChangeOnBothSidesNeedsNoSend() {
        var changed = base
        changed["name"] = .text("Home")
        let serverRecord = record(changed, at: 20)
        let result = SyncMerge.merge(local: record(changed, at: 30), server: serverRecord, base: .mirror(record(base, at: 10)))
        #expect(!result.needsSend)
        #expect(result.record == serverRecord)
    }

    @Test func removedFieldStaysRemoved() {
        // A pinned tab moved out of its folder has no `folder` field.
        let inFolder: [String: SyncValue] = ["persona": .reference("default"), "space": .reference("space-1"), "folder": .reference("folder-1"), "url": .text("https://example.org/"), "order": .number(1)]
        var outside = inFolder
        outside["folder"] = nil

        let removedHere = SyncMerge.merge(local: record(type: .tab, name: "tab-1", outside, at: 20), server: record(type: .tab, name: "tab-1", inFolder, at: 10), base: .mirror(record(type: .tab, name: "tab-1", inFolder, at: 10)))
        #expect(removedHere.needsSend)
        #expect(removedHere.record[.folder] == nil)

        let removedOnServer = SyncMerge.merge(local: record(type: .tab, name: "tab-1", inFolder, at: 30), server: record(type: .tab, name: "tab-1", outside, at: 20), base: .mirror(record(type: .tab, name: "tab-1", inFolder, at: 10)))
        #expect(!removedOnServer.needsSend)
        #expect(removedOnServer.record[.folder] == nil)
    }

    @Test func laterEditWinsBetweenARemovalAndANewValue() {
        let inFolder: [String: SyncValue] = ["persona": .reference("default"), "space": .reference("space-1"), "folder": .reference("folder-1")]
        var outside = inFolder
        outside["folder"] = nil
        var inOtherFolder = inFolder
        inOtherFolder["folder"] = .reference("folder-2")
        let tabBase = record(type: .tab, name: "tab-1", inFolder, at: 10)

        let removalLater = SyncMerge.merge(local: record(type: .tab, name: "tab-1", outside, at: 30), server: record(type: .tab, name: "tab-1", inOtherFolder, at: 20), base: .mirror(tabBase))
        #expect(removalLater.needsSend)
        #expect(removalLater.record[.folder] == nil)

        let moveLater = SyncMerge.merge(local: record(type: .tab, name: "tab-1", outside, at: 20), server: record(type: .tab, name: "tab-1", inOtherFolder, at: 30), base: .mirror(tabBase))
        #expect(!moveLater.needsSend)
        #expect(moveLater.record[.folder] == .reference("folder-2"))
    }

    @Test func settingFirstWrittenOnTwoMacsTakesTheLaterValue() {
        // A `Setting` has a fixed record name, so two Macs that first write it while sync runs meet without a base.
        func setting(_ value: String, at seconds: TimeInterval) -> SyncRecord {
            record(type: .setting, name: "ARCHAppearance", ["value": .text(value)], at: seconds)
        }

        let localLater = SyncMerge.merge(local: setting("dark", at: 20), server: setting("light", at: 10), base: .firstWrite)
        #expect(localLater.needsSend)
        #expect(localLater.record == setting("dark", at: 20))

        let serverLater = SyncMerge.merge(local: setting("dark", at: 10), server: setting("light", at: 20), base: .firstWrite)
        #expect(!serverLater.needsSend)
        #expect(serverLater.record == setting("light", at: 20))

        let tie = SyncMerge.merge(local: setting("dark", at: 20), server: setting("light", at: 20), base: .firstWrite)
        #expect(!tie.needsSend)
        #expect(tie.record[.value] == .text("light"))

        let same = SyncMerge.merge(local: setting("dark", at: 30), server: setting("dark", at: 20), base: .firstWrite)
        #expect(!same.needsSend)
        #expect(same.record == setting("dark", at: 20))
    }

    @Test func withoutABaseAFieldOnlyOneSideHasSurvives() {
        let local = record(["name": .text("Work"), "symbol": .text("star")], at: 30)
        let server = record(["name": .text("Work"), "homeURL": .text("https://example.org/")], at: 20)
        let result = SyncMerge.merge(local: local, server: server, base: .firstWrite)
        #expect(result.needsSend)
        #expect(result.record.fields == ["name": .text("Work"), "symbol": .text("star"), "homeURL": .text("https://example.org/")])
    }

    @Test func firstSyncKeepsTheServerValuesOfARecordBothMacsHave() {
        // This Mac's values were found when sync turned on, so their times are later than any edit on the server (docs/sync.md, First sync on a Mac).
        let serverPersona = record(type: .persona, name: "default", ["name": .text("Me"), "order": .number(0)], times: ["name": 400, "order": 100], at: 500)
        let persona = SyncMerge.merge(local: record(type: .persona, name: "default", ["name": .text("Default"), "order": .number(0)], times: ["name": 1000, "order": 1000], at: 1000), server: serverPersona, base: .firstSync)
        #expect(!persona.needsSend)
        #expect(persona.record == serverPersona)

        // A field that only this Mac has fills the server's record.
        let serverSpace = record(["persona": .reference("default"), "name": .text("Renamed on A"), "tint": .text("purple"), "order": .number(1)], at: 500)
        let space = SyncMerge.merge(local: record(["persona": .reference("default"), "name": .text("Work"), "tint": .text("blue"), "symbol": .text("star"), "order": .number(1)], times: ["symbol": 1000], at: 1000), server: serverSpace, base: .firstSync)
        #expect(space.needsSend)
        #expect(space.record.fields == ["persona": .reference("default"), "name": .text("Renamed on A"), "tint": .text("purple"), "symbol": .text("star"), "order": .number(1)])
        #expect(space.record.fieldModifiedAt == ["symbol": date(1000)])

        // A unit counts as a whole: the server's place has no folder, so the tab leaves this Mac's folder.
        let serverTab = record(type: .tab, name: "tab-1", ["persona": .reference("default"), "space": .reference("space-1"), "order": .number(1)], at: 500)
        let tab = SyncMerge.merge(local: record(type: .tab, name: "tab-1", ["persona": .reference("default"), "space": .reference("space-1"), "folder": .reference("folder-1"), "order": .number(2)], at: 1000), server: serverTab, base: .firstSync)
        #expect(!tab.needsSend)
        #expect(tab.record == serverTab)

        let setting = SyncMerge.merge(local: record(type: .setting, name: "ARCHAppearance", ["value": .text("dark")], at: 1000), server: record(type: .setting, name: "ARCHAppearance", ["value": .text("light")], at: 500), base: .firstSync)
        #expect(!setting.needsSend)
        #expect(setting.record[.value] == .text("light"))
    }

    @Test func eachFieldKeepsItsOwnEditTime() {
        // A later edit of one field does not make an earlier edit of another field win.
        let allAt5: [String: TimeInterval] = ["persona": 5, "name": 5, "tint": 5, "order": 5]
        let spaceBase = record(base, times: allAt5, at: 5)
        var renamedOnB = base
        renamedOnB["name"] = .text("Renamed on B")
        renamedOnB["tint"] = .text("green")
        var renamedOnA = base
        renamedOnA["name"] = .text("Renamed on A")

        // B renames the space offline at 10 and changes its tint at 40, while A renames it at 30.
        var offlineTimes = allAt5
        offlineTimes["name"] = 10
        offlineTimes["tint"] = 40
        var onlineTimes = allAt5
        onlineTimes["name"] = 30
        let reconnected = SyncMerge.merge(local: record(renamedOnB, times: offlineTimes, at: 40), server: record(renamedOnA, times: onlineTimes, at: 30), base: .mirror(spaceBase))
        #expect(reconnected.needsSend)
        #expect(reconnected.record.fields == ["persona": .reference("default"), "name": .text("Renamed on A"), "tint": .text("green"), "order": .number(1)])
        #expect(reconnected.record.fieldModifiedAt == ["persona": date(5), "name": date(30), "tint": date(40), "order": date(5)])
        #expect(reconnected.record.modifiedAt == date(40))

        // B renames it at 20 and changes its tint at 50, sending both, while A renames it offline at 30.
        var sentTimes = allAt5
        sentTimes["name"] = 20
        sentTimes["tint"] = 50
        var pendingTimes = allAt5
        pendingTimes["name"] = 30
        let afterOffline = SyncMerge.merge(local: record(renamedOnA, times: pendingTimes, at: 30), server: record(renamedOnB, times: sentTimes, at: 50), base: .mirror(spaceBase))
        #expect(afterOffline.needsSend)
        #expect(afterOffline.record.fields == ["persona": .reference("default"), "name": .text("Renamed on A"), "tint": .text("green"), "order": .number(1)])
        #expect(afterOffline.record.fieldModifiedAt == ["persona": date(5), "name": date(30), "tint": date(50), "order": date(5)])
        #expect(afterOffline.record.modifiedAt == date(50))
    }

    @Test func aPinnedTabsPlaceMergesAsOneUnit() {
        // A moves the tab out of folders into another space while B moves it into another folder of its space.
        let inFolder: [String: SyncValue] = ["persona": .reference("default"), "space": .reference("space-1"), "folder": .reference("folder-1"), "url": .text("https://example.org/"), "order": .number(1)]
        var otherSpace = inFolder
        otherSpace["space"] = .reference("space-2")
        otherSpace["folder"] = nil
        otherSpace["order"] = .number(3)
        var otherFolder = inFolder
        otherFolder["folder"] = .reference("folder-3")
        otherFolder["order"] = .number(2)
        func tab(_ fields: [String: SyncValue], movedAt seconds: TimeInterval, spaceAt spaceSeconds: TimeInterval) -> SyncRecord {
            record(type: .tab, name: "tab-1", fields, times: ["persona": 5, "space": spaceSeconds, "folder": seconds, "url": 5, "order": seconds], at: seconds)
        }
        let tabBase = tab(inFolder, movedAt: 5, spaceAt: 5)
        let movedToFolder = tab(otherFolder, movedAt: 30, spaceAt: 5)

        // B's later move takes the whole place, so the tab stays in space-1 with folder-3, never in space-2 with it.
        let folderLater = SyncMerge.merge(local: tab(otherSpace, movedAt: 20, spaceAt: 20), server: movedToFolder, base: .mirror(tabBase))
        #expect(!folderLater.needsSend)
        #expect(folderLater.record == movedToFolder)

        let spaceLater = SyncMerge.merge(local: tab(otherSpace, movedAt: 40, spaceAt: 40), server: movedToFolder, base: .mirror(tabBase))
        #expect(spaceLater.needsSend)
        #expect(spaceLater.record.fields == otherSpace)
        #expect(spaceLater.record.fieldModifiedAt == ["persona": date(5), "space": date(40), "folder": date(40), "url": date(5), "order": date(40)])
    }

    @Test func aFoldersPlaceMergesAsOneUnitAndItsNameApart() {
        // A renames the folder and moves it to the top of another space while B moves it under another folder of its space.
        let nested: [String: SyncValue] = ["persona": .reference("default"), "space": .reference("space-1"), "parent": .reference("folder-1"), "name": .text("News"), "order": .number(1)]
        var topOfOtherSpace = nested
        topOfOtherSpace["space"] = .reference("space-2")
        topOfOtherSpace["parent"] = nil
        topOfOtherSpace["order"] = .number(2)
        topOfOtherSpace["name"] = .text("Reading")
        var underOtherFolder = nested
        underOtherFolder["parent"] = .reference("folder-3")
        underOtherFolder["order"] = .number(4)
        let allAt5: [String: TimeInterval] = ["persona": 5, "space": 5, "parent": 5, "name": 5, "order": 5]
        var movedAndRenamedTimes = allAt5
        for field in ["space", "parent", "order", "name"] { movedAndRenamedTimes[field] = 20 }
        var movedTimes = allAt5
        movedTimes["parent"] = 30
        movedTimes["order"] = 30

        let result = SyncMerge.merge(
            local: record(type: .folder, name: "folder-2", topOfOtherSpace, times: movedAndRenamedTimes, at: 20),
            server: record(type: .folder, name: "folder-2", underOtherFolder, times: movedTimes, at: 30),
            base: .mirror(record(type: .folder, name: "folder-2", nested, times: allAt5, at: 5))
        )
        #expect(result.needsSend)
        #expect(result.record.fields == ["persona": .reference("default"), "space": .reference("space-1"), "parent": .reference("folder-3"), "name": .text("Reading"), "order": .number(4)])
    }

    @Test(arguments: [SyncRecordType.favorite, .tab])
    func aSavedPageMergesAsOneUnit(type: SyncRecordType) {
        // A edits only the address at 30 while B makes another page the saved page at 20, so the address never takes B's title.
        let page: [String: SyncValue] = ["persona": .reference("default"), "url": .text("https://old.example/"), "title": .text("Old")]
        var addressEdited = page
        addressEdited["url"] = .text("https://a.example/")
        var pageReplaced = page
        pageReplaced["url"] = .text("https://b.example/")
        pageReplaced["title"] = .text("B Page")
        let pageBase = record(type: type, name: "item-1", page, times: ["persona": 5, "url": 5, "title": 5], at: 5)

        let addressLater = SyncMerge.merge(
            local: record(type: type, name: "item-1", addressEdited, times: ["persona": 5, "url": 30, "title": 5], at: 30),
            server: record(type: type, name: "item-1", pageReplaced, times: ["persona": 5, "url": 20, "title": 20], at: 20),
            base: .mirror(pageBase)
        )
        #expect(addressLater.needsSend)
        #expect(addressLater.record.fields == addressEdited)
        #expect(addressLater.record.fieldModifiedAt == ["persona": date(5), "url": date(30), "title": date(5)])

        let replacedServer = record(type: type, name: "item-1", pageReplaced, times: ["persona": 5, "url": 40, "title": 40], at: 40)
        let pageLater = SyncMerge.merge(
            local: record(type: type, name: "item-1", addressEdited, times: ["persona": 5, "url": 30, "title": 5], at: 30),
            server: replacedServer,
            base: .mirror(pageBase)
        )
        #expect(!pageLater.needsSend)
        #expect(pageLater.record == replacedServer)
    }

    @Test func fieldUnknownToThisBuildSurvives() {
        // `futureField` stands for a field that a newer build writes on folders (docs/sync.md, Schema versions); this build's records never have it.
        let known: [String: SyncValue] = ["persona": .reference("default"), "space": .reference("space-1"), "name": .text("News")]
        var serverFields = known
        serverFields["futureField"] = .text("feed-2")
        var baseFields = known
        baseFields["futureField"] = .text("feed-1")
        var local = known
        local["name"] = .text("Reading")

        let changedOnServer = SyncMerge.merge(local: record(type: .folder, name: "folder-1", local, at: 30), server: record(type: .folder, name: "folder-1", serverFields, at: 20, schemaVersion: 2), base: .mirror(record(type: .folder, name: "folder-1", baseFields, at: 10, schemaVersion: 2)))
        #expect(changedOnServer.needsSend)
        #expect(changedOnServer.record[.name] == .text("Reading"))
        #expect(changedOnServer.record.fields["futureField"] == .text("feed-2"))
        #expect(changedOnServer.record.schemaVersion == 2)

        let unchanged = SyncMerge.merge(local: record(type: .folder, name: "folder-1", local, at: 30), server: record(type: .folder, name: "folder-1", baseFields, at: 10, schemaVersion: 2), base: .mirror(record(type: .folder, name: "folder-1", baseFields, at: 10, schemaVersion: 2)))
        #expect(unchanged.record.fields["futureField"] == .text("feed-1"))

        let withoutBase = SyncMerge.merge(local: record(type: .folder, name: "folder-1", local, at: 30), server: record(type: .folder, name: "folder-1", serverFields, at: 20, schemaVersion: 2), base: .firstWrite)
        #expect(withoutBase.record.fields["futureField"] == .text("feed-2"))
        #expect(withoutBase.record[.name] == .text("Reading"))

        // This Mac cannot edit a field it does not know, even one with a name it uses for other types.
        var localWithOtherValues = local
        localWithOtherValues["futureField"] = .text("feed-3")
        localWithOtherValues["url"] = .text("https://example.org/")
        var serverWithURL = serverFields
        serverWithURL["url"] = .text("https://example.com/")
        let ignored = SyncMerge.merge(local: record(type: .folder, name: "folder-1", localWithOtherValues, at: 30), server: record(type: .folder, name: "folder-1", serverWithURL, at: 20, schemaVersion: 2), base: .mirror(record(type: .folder, name: "folder-1", baseFields, at: 10, schemaVersion: 2)))
        #expect(ignored.record.fields["futureField"] == .text("feed-2"))
        #expect(ignored.record.fields["url"] == .text("https://example.com/"))
    }

    @Test func eachTypeListsTheFieldsOfTheSchema() {
        // docs/sync.md, Record types. Deployed record types and fields can never be removed or change type, so these lists only grow, apart from `Folder`'s `live`, which stays in the schema and on the server while this build no longer reads or writes it (live folders were removed).
        #expect(SyncRecordType.persona.fields == [.name, .order])
        #expect(SyncRecordType.space.fields == [.persona, .name, .symbol, .tint, .homeURL, .order])
        #expect(SyncRecordType.folder.fields == [.persona, .space, .parent, .name, .order])
        #expect(SyncRecordType.favorite.fields == [.persona, .url, .title, .order])
        #expect(SyncRecordType.tab.fields == [.persona, .space, .folder, .url, .title, .customTitle, .engine, .order])
        #expect(SyncRecordType.setting.fields == [.value])
        #expect(SyncRecordType.allCases.map(\.rawValue) == ["Persona", "Space", "Folder", "Favorite", "Tab", "Setting"])
    }

    @Test func eachTypeListsItsMergeUnits() {
        // docs/sync.md, Conflicts: a pinned tab's or folder's place and a saved page merge as one unit.
        #expect(SyncRecordType.persona.fieldGroups.isEmpty)
        #expect(SyncRecordType.space.fieldGroups.isEmpty)
        #expect(SyncRecordType.folder.fieldGroups == [[.space, .parent, .order]])
        #expect(SyncRecordType.favorite.fieldGroups == [[.url, .title]])
        #expect(SyncRecordType.tab.fieldGroups == [[.space, .folder, .order], [.url, .title]])
        #expect(SyncRecordType.setting.fieldGroups.isEmpty)
        for type in SyncRecordType.allCases {
            let groupedFields = type.fieldGroups.flatMap { $0 }
            #expect(Set(groupedFields).isSubset(of: type.fields), "\(type) groups only its own fields")
            #expect(Set(groupedFields).count == groupedFields.count, "\(type) puts each field in one group at most")
        }
    }
}
