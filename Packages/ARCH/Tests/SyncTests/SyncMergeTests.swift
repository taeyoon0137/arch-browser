// The per-field merge of this Mac's record with the server's against the mirror's copy (docs/sync.md, Conflicts; sync decision 3).
import Foundation
import Testing
@testable import Sync

@Suite struct SyncMergeTests {
    private func record(type: SyncRecordType = .space, name: String = "space-1", _ fields: [String: SyncValue], at seconds: TimeInterval, schemaVersion: Int = 1) -> SyncRecord {
        SyncRecord(recordType: type, recordName: name, fields: fields, modifiedAt: Date(timeIntervalSinceReferenceDate: seconds), schemaVersion: schemaVersion)
    }

    private let base: [String: SyncValue] = ["persona": .reference("default"), "name": .text("Work"), "tint": .text("blue"), "order": .number(1)]

    @Test func fieldChangedOnlyHereIsSent() {
        var local = base
        local["name"] = .text("Home")
        let result = SyncMerge.merge(local: record(local, at: 20), server: record(base, at: 10), base: record(base, at: 10))
        #expect(result.needsSend)
        #expect(result.record.fields == local)
        #expect(result.record.modifiedAt == Date(timeIntervalSinceReferenceDate: 20))
    }

    @Test func fieldChangedOnlyOnTheServerNeedsNoSend() {
        var server = base
        server["name"] = .text("Home")
        let serverRecord = record(server, at: 10)
        let result = SyncMerge.merge(local: record(base, at: 30), server: serverRecord, base: record(base, at: 5))
        #expect(!result.needsSend)
        #expect(result.record == serverRecord)
    }

    @Test func unchangedRecordNeedsNoSend() {
        let serverRecord = record(base, at: 10)
        let result = SyncMerge.merge(local: record(base, at: 10), server: serverRecord, base: serverRecord)
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
        let result = SyncMerge.merge(local: record(local, at: times.local), server: record(server, at: times.server), base: record(base, at: 10))
        #expect(result.needsSend)
        #expect(result.record.fields == ["persona": .reference("default"), "name": .text("Home"), "tint": .text("green"), "order": .number(1.5)])
        #expect(result.record.modifiedAt == Date(timeIntervalSinceReferenceDate: 30))
    }

    @Test func laterEditWinsAFieldChangedOnBothSides() {
        var local = base
        local["name"] = .text("Home")
        var server = base
        server["name"] = .text("Office")

        let localLater = SyncMerge.merge(local: record(local, at: 30), server: record(server, at: 20), base: record(base, at: 10))
        #expect(localLater.needsSend)
        #expect(localLater.record[.name] == .text("Home"))

        let serverRecord = record(server, at: 30)
        let serverLater = SyncMerge.merge(local: record(local, at: 20), server: serverRecord, base: record(base, at: 10))
        #expect(!serverLater.needsSend)
        #expect(serverLater.record == serverRecord)
    }

    @Test func serverWinsATie() {
        var local = base
        local["name"] = .text("Home")
        var server = base
        server["name"] = .text("Office")
        let serverRecord = record(server, at: 20)
        let result = SyncMerge.merge(local: record(local, at: 20), server: serverRecord, base: record(base, at: 10))
        #expect(!result.needsSend)
        #expect(result.record == serverRecord)
    }

    @Test func sameChangeOnBothSidesNeedsNoSend() {
        var changed = base
        changed["name"] = .text("Home")
        let serverRecord = record(changed, at: 20)
        let result = SyncMerge.merge(local: record(changed, at: 30), server: serverRecord, base: record(base, at: 10))
        #expect(!result.needsSend)
        #expect(result.record == serverRecord)
    }

    @Test func removedFieldStaysRemoved() {
        // A pinned tab moved out of its folder has no `folder` field.
        let inFolder: [String: SyncValue] = ["persona": .reference("default"), "space": .reference("space-1"), "folder": .reference("folder-1"), "url": .text("https://example.org/"), "order": .number(1)]
        var outside = inFolder
        outside["folder"] = nil

        let removedHere = SyncMerge.merge(local: record(type: .tab, name: "tab-1", outside, at: 20), server: record(type: .tab, name: "tab-1", inFolder, at: 10), base: record(type: .tab, name: "tab-1", inFolder, at: 10))
        #expect(removedHere.needsSend)
        #expect(removedHere.record[.folder] == nil)

        let removedOnServer = SyncMerge.merge(local: record(type: .tab, name: "tab-1", inFolder, at: 30), server: record(type: .tab, name: "tab-1", outside, at: 20), base: record(type: .tab, name: "tab-1", inFolder, at: 10))
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

        let removalLater = SyncMerge.merge(local: record(type: .tab, name: "tab-1", outside, at: 30), server: record(type: .tab, name: "tab-1", inOtherFolder, at: 20), base: tabBase)
        #expect(removalLater.needsSend)
        #expect(removalLater.record[.folder] == nil)

        let moveLater = SyncMerge.merge(local: record(type: .tab, name: "tab-1", outside, at: 20), server: record(type: .tab, name: "tab-1", inOtherFolder, at: 30), base: tabBase)
        #expect(!moveLater.needsSend)
        #expect(moveLater.record[.folder] == .reference("folder-2"))
    }

    @Test func settingFirstWrittenOnTwoMacsTakesTheLaterValue() {
        // A `Setting` has a fixed record name, so two Macs that first write it meet without a base.
        func setting(_ value: String, at seconds: TimeInterval) -> SyncRecord {
            record(type: .setting, name: "ARCHAppearance", ["value": .text(value)], at: seconds)
        }

        let localLater = SyncMerge.merge(local: setting("dark", at: 20), server: setting("light", at: 10), base: nil)
        #expect(localLater.needsSend)
        #expect(localLater.record == setting("dark", at: 20))

        let serverLater = SyncMerge.merge(local: setting("dark", at: 10), server: setting("light", at: 20), base: nil)
        #expect(!serverLater.needsSend)
        #expect(serverLater.record == setting("light", at: 20))

        let tie = SyncMerge.merge(local: setting("dark", at: 20), server: setting("light", at: 20), base: nil)
        #expect(!tie.needsSend)
        #expect(tie.record[.value] == .text("light"))

        let same = SyncMerge.merge(local: setting("dark", at: 30), server: setting("dark", at: 20), base: nil)
        #expect(!same.needsSend)
        #expect(same.record == setting("dark", at: 20))
    }

    @Test func withoutABaseAFieldOnlyOneSideHasSurvives() {
        let local = record(["name": .text("Work"), "symbol": .text("star")], at: 30)
        let server = record(["name": .text("Work"), "homeURL": .text("https://example.org/")], at: 20)
        let result = SyncMerge.merge(local: local, server: server, base: nil)
        #expect(result.needsSend)
        #expect(result.record.fields == ["name": .text("Work"), "symbol": .text("star"), "homeURL": .text("https://example.org/")])
    }

    @Test func fieldUnknownToThisBuildSurvives() {
        // `live` stands for a field that a newer build writes on folders (docs/sync.md, Schema versions); this build's records never have it.
        let known: [String: SyncValue] = ["persona": .reference("default"), "space": .reference("space-1"), "name": .text("News")]
        var serverFields = known
        serverFields["live"] = .text("feed-2")
        var baseFields = known
        baseFields["live"] = .text("feed-1")
        var local = known
        local["name"] = .text("Reading")

        let changedOnServer = SyncMerge.merge(local: record(type: .folder, name: "folder-1", local, at: 30), server: record(type: .folder, name: "folder-1", serverFields, at: 20, schemaVersion: 2), base: record(type: .folder, name: "folder-1", baseFields, at: 10, schemaVersion: 2))
        #expect(changedOnServer.needsSend)
        #expect(changedOnServer.record[.name] == .text("Reading"))
        #expect(changedOnServer.record.fields["live"] == .text("feed-2"))
        #expect(changedOnServer.record.schemaVersion == 2)

        let unchanged = SyncMerge.merge(local: record(type: .folder, name: "folder-1", local, at: 30), server: record(type: .folder, name: "folder-1", baseFields, at: 10, schemaVersion: 2), base: record(type: .folder, name: "folder-1", baseFields, at: 10, schemaVersion: 2))
        #expect(unchanged.record.fields["live"] == .text("feed-1"))

        let withoutBase = SyncMerge.merge(local: record(type: .folder, name: "folder-1", local, at: 30), server: record(type: .folder, name: "folder-1", serverFields, at: 20, schemaVersion: 2), base: nil)
        #expect(withoutBase.record.fields["live"] == .text("feed-2"))
        #expect(withoutBase.record[.name] == .text("Reading"))

        // This Mac cannot edit a field it does not know, even one with a name it uses for other types.
        var localWithOtherValues = local
        localWithOtherValues["live"] = .text("feed-3")
        localWithOtherValues["url"] = .text("https://example.org/")
        var serverWithURL = serverFields
        serverWithURL["url"] = .text("https://example.com/")
        let ignored = SyncMerge.merge(local: record(type: .folder, name: "folder-1", localWithOtherValues, at: 30), server: record(type: .folder, name: "folder-1", serverWithURL, at: 20, schemaVersion: 2), base: record(type: .folder, name: "folder-1", baseFields, at: 10, schemaVersion: 2))
        #expect(ignored.record.fields["live"] == .text("feed-2"))
        #expect(ignored.record.fields["url"] == .text("https://example.com/"))
    }

    @Test func eachTypeListsTheFieldsOfTheSchema() {
        // docs/sync.md, Record types. Deployed record types and fields can never be removed or change type, so these lists only grow.
        #expect(SyncRecordType.persona.fields == [.name, .order])
        #expect(SyncRecordType.space.fields == [.persona, .name, .symbol, .tint, .homeURL, .order])
        #expect(SyncRecordType.folder.fields == [.persona, .space, .parent, .name, .order])
        #expect(SyncRecordType.favorite.fields == [.persona, .url, .title, .order])
        #expect(SyncRecordType.tab.fields == [.persona, .space, .folder, .url, .title, .customTitle, .engine, .order])
        #expect(SyncRecordType.setting.fields == [.value])
        #expect(SyncRecordType.allCases.map(\.rawValue) == ["Persona", "Space", "Folder", "Favorite", "Tab", "Setting"])
    }
}
