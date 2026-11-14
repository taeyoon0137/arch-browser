// `sync.json`: the sync engine's state, the mirror, and the pending saves (docs/sync.md, Mapping the session store to records and Offline behavior). Each test writes in a temporary folder of its own.
import CloudKit
import Foundation
import Testing
@testable import Sync

@Suite struct SyncMirrorTests {
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
            try SyncMirror(engineState: engineState, records: ["space-1": mirrored, "theme-1": theme], pendingSaves: [pendingTab, renamed, unusable]).write(to: url)

            let read = SyncMirror.read(from: url)
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
            try SyncMirror().write(to: url)
            #expect(SyncMirror.read(from: url).isEmpty)
        }
    }

    @Test func readsAMissingOrUnreadableFileAsEmpty() throws {
        try withFolder { folder in
            let url = folder.appendingPathComponent(SyncMirror.fileName)
            #expect(SyncMirror.read(from: url).isEmpty)

            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("not JSON".utf8).write(to: url)
            #expect(SyncMirror.read(from: url).isEmpty)

            // A file whose records do not unarchive.
            let base64 = Data("not an archive".utf8).base64EncodedString()
            try Data(#"{"version":1,"engineState":"\#(base64)","records":"\#(base64)","pendingSaves":[]}"#.utf8).write(to: url)
            #expect(SyncMirror.read(from: url).isEmpty)

            // A file from a newer format, and one with a pending save of an unknown type.
            try SyncMirror(engineState: Data("state".utf8), pendingSaves: [space]).write(to: url)
            #expect(SyncMirror.read(from: url).engineState == Data("state".utf8))
            let written = try String(contentsOf: url, encoding: .utf8)
            try Data(written.replacingOccurrences(of: #""version":1"#, with: #""version":2"#).utf8).write(to: url)
            #expect(SyncMirror.read(from: url).isEmpty)
            try Data(written.replacingOccurrences(of: #""recordType":"Space""#, with: #""recordType":"Theme""#).utf8).write(to: url)
            #expect(SyncMirror.read(from: url).isEmpty)
        }
    }
}
