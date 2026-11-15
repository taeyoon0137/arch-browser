// `sync.json`: the sync engine's state, the mirror, and the pending saves (docs/sync.md, Mapping the session store to records and Offline behavior). Each test writes in a temporary folder of its own.
import CloudKit
import Foundation
import Testing
@testable import Sync

@Suite struct SyncMirrorTests {
    /// A placeholder database.
    private let database = SyncDatabase(containerIdentifier: "iCloud.example.first", environment: "Production")

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// A temporary folder for the test, removed when `body` returns.
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncMirrorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private var space: SyncRecord {
        SyncRecord(recordType: .space, recordName: "space-1",
                   fields: ["persona": .reference("default"), "name": .text("Work"), "tint": .text("blue"), "order": .number(1)],
                   fieldModifiedAt: ["persona": date(5), "name": date(5.25), "tint": date(5), "order": date(5)], modifiedAt: date(5.25))
    }

    @Test func readsBackAWrittenFile() throws {
        try withFolder { folder in
            let url = folder.appendingPathComponent("Arch", isDirectory: true).appendingPathComponent(SyncMirror.fileName)
            let mirrored = SyncCloudKitRecords.ckRecord(from: space)
            // A record of a type that only a newer build writes stays in the mirror as it came.
            let theme = CKRecord(recordType: "Theme", recordID: SyncCloudKitRecords.recordID(named: "theme-1"))
            theme.encryptedValues["name"] = "Dusk"
            theme["reviewedAt"] = date(7)
            let pendingTab = SyncRecord(
                recordType: .tab, recordName: "tab-1",
                fields: ["persona": .reference("default"), "space": .reference("space-1"), "url": .text("https://a.example/"), "title": .text("A"), "order": .number(1.5), "live": .text("from a newer build")],
                fieldModifiedAt: ["url": date(20.000001), "title": date(20.000001), "order": date(21), "folder": date(21)], modifiedAt: date(21), schemaVersion: 2
            )
            var renamed = space
            renamed[.name] = .text("Home")
            renamed.fieldModifiedAt["name"] = date(22)
            // An unusable order key, which JSON has no number for, survives as it is.
            var unusable = renamed
            unusable.recordName = "space-2"
            unusable[.order] = .number(.infinity)
            let engineState = Data("engine state".utf8)
            try SyncMirror(engineState: engineState, records: ["space-1": mirrored, "theme-1": theme], pendingSaves: [pendingTab, renamed, unusable]).write(to: url, database: database)

            let read = SyncMirror.read(from: url, database: database)
            #expect(read.engineState == engineState)
            #expect(read.pendingSaves == [pendingTab, renamed, unusable])
            #expect(Set(read.records.keys) == ["space-1", "theme-1"])
            let readSpace = try #require(read.records["space-1"])
            #expect(SyncCloudKitRecords.syncRecord(from: readSpace) == space)
            #expect(readSpace.recordID.zoneID == SyncCloudKitRecords.zoneID)
            #expect(readSpace.encryptedValues["name"] as? String == "Work")
            let readTheme = try #require(read.records["theme-1"])
            #expect(readTheme.recordType == "Theme")
            #expect(readTheme.encryptedValues["name"] as? String == "Dusk")
            #expect(readTheme["reviewedAt"] as? Date == date(7))

            // Writing again replaces the file.
            try SyncMirror().write(to: url, database: database)
            #expect(SyncMirror.read(from: url, database: database).isEmpty)
        }
    }

    /// The names of the files in `folder`, sorted.
    private func fileNames(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func readsAMissingFileAsEmptyAndLeavesNoCopy() throws {
        try withFolder { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #expect(SyncMirror.read(from: folder.appendingPathComponent(SyncMirror.fileName), database: database).isEmpty)
            #expect(try fileNames(in: folder).isEmpty)
        }
    }

    @Test func readsAnUnreadableFileAsEmptyAndMovesItAside() throws {
        try withFolder { folder in
            let url = folder.appendingPathComponent(SyncMirror.fileName)
            let copy = folder.appendingPathComponent("sync.unreadable.json")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("not JSON".utf8).write(to: url)
            #expect(SyncMirror.read(from: url, database: database).isEmpty)
            #expect(try fileNames(in: folder) == ["sync.unreadable.json"])
            #expect(try Data(contentsOf: copy) == Data("not JSON".utf8))

            // A file whose records do not unarchive replaces the older copy.
            let base64 = Data("not an archive".utf8).base64EncodedString()
            let unarchivable = Data(#"{"version":1,"database":"\#(database.digest)","engineState":"\#(base64)","records":"\#(base64)","pendingSaves":[]}"#.utf8)
            try unarchivable.write(to: url)
            #expect(SyncMirror.read(from: url, database: database).isEmpty)
            #expect(try fileNames(in: folder) == ["sync.unreadable.json"])
            #expect(try Data(contentsOf: copy) == unarchivable)
        }
    }

    @Test func readsAnotherDatabasesFileAsEmptyAndMovesItAside() throws {
        try withFolder { folder in
            let url = folder.appendingPathComponent(SyncMirror.fileName)
            let copy = folder.appendingPathComponent("sync.other-database.json")
            let mirror = SyncMirror(engineState: Data("state".utf8), records: ["space-1": SyncCloudKitRecords.ckRecord(from: space)], pendingSaves: [space])
            // The file names the database only by its digest.
            try mirror.write(to: url, database: database)
            let written = try Data(contentsOf: url)
            #expect(!String(decoding: written, as: UTF8.self).contains(database.containerIdentifier))
            #expect(String(decoding: written, as: UTF8.self).contains(database.digest))

            // A build for the Development environment, another container, or without the environment entitlement uses another database.
            let others = [
                SyncDatabase(containerIdentifier: database.containerIdentifier, environment: "Development"),
                SyncDatabase(containerIdentifier: "iCloud.example.second", environment: "Production"),
                SyncDatabase(containerIdentifier: database.containerIdentifier, environment: nil),
            ]
            for other in others {
                #expect(other.digest != database.digest)
                try written.write(to: url)
                #expect(SyncMirror.read(from: url, database: other).isEmpty)
                #expect(try fileNames(in: folder) == ["sync.other-database.json"])
                #expect(try Data(contentsOf: copy) == written)
            }

            // The same database reads the file back.
            try written.write(to: url)
            let read = SyncMirror.read(from: url, database: SyncDatabase(containerIdentifier: database.containerIdentifier, environment: "Production"))
            #expect(read.engineState == mirror.engineState)
            #expect(read.pendingSaves == [space])
            #expect(Set(read.records.keys) == ["space-1"])
        }
    }

    @Test func readsANewerFormatAsEmptyAndKeepsACopy() throws {
        try withFolder { folder in
            let url = folder.appendingPathComponent(SyncMirror.fileName)
            try SyncMirror(engineState: Data("state".utf8), pendingSaves: [space]).write(to: url, database: database)
            let newer = Data(try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: #""version":1"#, with: #""version":2"#).utf8)
            try newer.write(to: url)
            #expect(SyncMirror.read(from: url, database: database).isEmpty)
            #expect(try fileNames(in: folder) == ["sync-v2.json", "sync.json"])
            #expect(try Data(contentsOf: folder.appendingPathComponent("sync-v2.json")) == newer)
        }
    }

    @Test func skipsOnlyThePendingSavesThisBuildCannotRead() throws {
        try withFolder { folder in
            let url = folder.appendingPathComponent(SyncMirror.fileName)
            var renamed = space
            renamed[.name] = .text("Home")
            renamed.fieldModifiedAt["name"] = date(22)
            // Two saves that a newer build wrote within the same format: one of a record type this build does not know, and one with a kind of value it does not know.
            var newType = space
            newType.recordName = "theme-1"
            let newValue = SyncRecord(recordType: .tab, recordName: "tab-1", fields: ["persona": .reference("default"), "reviewedAt": .text("placeholder")], modifiedAt: date(23))
            let engineState = Data("engine state".utf8)
            try SyncMirror(engineState: engineState, records: ["space-1": SyncCloudKitRecords.ckRecord(from: space)], pendingSaves: [renamed, newType, newValue]).write(to: url, database: database)
            let written = try String(contentsOf: url, encoding: .utf8)
            let newer = written
                .replacingOccurrences(of: #""recordName":"theme-1","recordType":"Space""#, with: #""recordName":"theme-1","recordType":"Theme""#)
                .replacingOccurrences(of: #""reviewedAt":{"text":"placeholder"}"#, with: #""reviewedAt":{"date":23}"#)
            #expect(newer != written)
            try Data(newer.utf8).write(to: url)

            let read = SyncMirror.read(from: url, database: database)
            #expect(read.engineState == engineState)
            #expect(Set(read.records.keys) == ["space-1"])
            #expect(read.pendingSaves == [renamed])
            #expect(try fileNames(in: folder) == ["sync.json"])
        }
    }

    @Test func skipsRecordsOfOtherZones() throws {
        try withFolder { folder in
            let url = folder.appendingPathComponent(SyncMirror.fileName)
            // A later build's zone holds a record of the same name whose values mean something else. Its key sorts first, so it would win a name clash.
            let laterZone = CKRecordZone.ID(zoneName: "ArchSync2", ownerName: CKCurrentUserDefaultName)
            let laterSpace = CKRecord(recordType: "Space", recordID: CKRecord.ID(recordName: "space-1", zoneID: laterZone))
            laterSpace.encryptedValues["name"] = "From the later zone"
            let laterOnly = CKRecord(recordType: "Space", recordID: CKRecord.ID(recordName: "space-2", zoneID: laterZone))
            let defaultZone = CKRecord(recordType: "Space", recordID: CKRecord.ID(recordName: "space-3"))
            try SyncMirror(records: ["a": laterSpace, "b": laterOnly, "c": defaultZone, "space-1": SyncCloudKitRecords.ckRecord(from: space)]).write(to: url, database: database)

            let read = SyncMirror.read(from: url, database: database)
            #expect(Set(read.records.keys) == ["space-1"])
            let readSpace = try #require(read.records["space-1"])
            #expect(readSpace.recordID.zoneID == SyncCloudKitRecords.zoneID)
            #expect(SyncCloudKitRecords.syncRecord(from: readSpace) == space)
        }
    }
}
