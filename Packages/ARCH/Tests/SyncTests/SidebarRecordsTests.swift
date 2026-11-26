import ARCHEngine
@testable import Browsing
import CloudKit
import Foundation
import Sync
import Testing

@Suite struct SidebarRecordsTests {
    @Test func mapsTheSavedSidebarInSiblingOrder() throws {
        let personal = Persona(id: Persona.defaultID, name: "Home"), work = Persona(name: "Work")
        var first = Space(name: "One", symbol: "star", tint: .green, personaID: work.id)
        let second = Space(name: "Two", personaID: work.id)
        let saved = URL(string: "https://example.test/bookmark")!
        first.homeURL = saved
        let ordinary = TabFolder(spaceID: first.id, name: "Outer", isPinned: true)
        let nested = TabFolder(spaceID: first.id, name: "News", isPinned: true, parentID: ordinary.id)
        let favorite = Favorite(url: saved, title: "Favorite", personaID: personal.id)
        let tab = SessionSnapshot.TabRecord(id: UUID(), spaceID: first.id, url: URL(string: "https://example.test/current"),
            title: "Current title", customTitle: "My tab", isPinned: true, folderID: ordinary.id, engine: .chromium,
            state: Data("engine state".utf8), personaID: work.id, savedPage: SavedPage(url: saved, title: "Saved title"))
        let snapshot = SessionSnapshot(personas: [personal, work], spaces: [first, second], currentSpaceID: first.id,
            favorites: [favorite], tabs: [tab], folders: [nested, ordinary])
        let state = SidebarSyncState(snapshot: snapshot, defaultEngine: .webKit)
        let date = Date(timeIntervalSinceReferenceDate: 30)
        let records = try SidebarRecords.records(from: state, foundAt: date)
        let byName = Dictionary(uniqueKeysWithValues: records.map { ($0.recordName, $0) })
        let tabName = try #require(tab.id?.uuidString)
        #expect(records.map(\.recordName) == ["default", work.id.uuidString, first.id.uuidString, second.id.uuidString,
                                              nested.id.uuidString, ordinary.id.uuidString, favorite.id.uuidString, tabName])
        #expect(byName["default"]?.fields == ["name": .text("Home"), "order": .number(1), "favoriteRows": .text("[]")])
        #expect(byName[work.id.uuidString]?[.order] == .number(2))
        #expect(byName[first.id.uuidString]?.fields == ["persona": .reference(work.id.uuidString), "name": .text("One"),
                "symbol": .text("star"), "tint": .text("green"), "homeURL": .text(saved.absoluteString), "order": .number(1)])
        #expect(byName[second.id.uuidString]?[.order] == .number(2))
        #expect(byName[favorite.id.uuidString]?.fields == ["persona": .reference("default"), "url": .text(saved.absoluteString),
                                                        "title": .text("Favorite"), "order": .number(1)])
        #expect(byName[tabName]?.fields == ["persona": .reference(work.id.uuidString), "space": .reference(first.id.uuidString),
                "folder": .reference(ordinary.id.uuidString), "url": .text(saved.absoluteString), "title": .text("Saved title"),
                "engine": .text("chromium"), "customTitle": .text("My tab"), "order": .number(1)])
        let item = try #require(byName[nested.id.uuidString])
        #expect(item.schemaVersion == 4)
        #expect(item[.tint] == nil)
        #expect(item[.parent] == .reference(ordinary.id.uuidString))
        #expect(item[.order] == .number(1))
        #expect(item.fields["live"] == nil)
        let later = date.addingTimeInterval(90)
        let same = try SidebarRecords.records(from: state, foundAt: later)
        let changes = SyncDiff.changes(local: same, scope: { $0.recordType != .setting }, mirror: records, pending: [], foundAt: later)
        #expect(changes.saves.isEmpty && changes.deletions.isEmpty)
    }

    @Test func favoriteRowsRoundTripAsAnEncryptedLayoutForEachPersona() throws {
        let home = Persona(id: Persona.defaultID, name: "Home", favoriteRows: [1, 2, 1])
        let work = Persona(name: "Work", favoriteRows: [3, 1])
        let spaces = [Space(name: "Personal", personaID: home.id), Space(name: "Projects", personaID: work.id)]
        let favorites = [home, work].flatMap { persona in
            (0..<4).map { Favorite(url: URL(string: "https://example.test/\(persona.id)/\($0)")!, title: "Favorite \($0)", personaID: persona.id) }
        }
        let state = SidebarSyncState(personas: [home, work], spaces: spaces, folders: [], favorites: favorites, pinnedTabs: [])
        let date = Date(timeIntervalSinceReferenceDate: 30)
        let records = try SidebarRecords.records(from: state, foundAt: date)
        let cloud = records.map { SyncCloudKitRecords.ckRecord(from: $0) }
        let homeRecord = try #require(cloud.first { $0.recordID.recordName == "default" })
        let workRecord = try #require(cloud.first { $0.recordID.recordName == work.id.uuidString })
        #expect(homeRecord.encryptedValues["favoriteRows"] as? String == "[1,2,1]")
        #expect(workRecord.encryptedValues["favoriteRows"] as? String == "[3,1]")
        #expect(homeRecord["favoriteRows"] == nil && workRecord["favoriteRows"] == nil)
        let fetched = try cloud.map { try #require(SyncCloudKitRecords.syncRecord(from: $0)) }
        let plan = try IncomingSidebarRecords.plan(records: fetched, deleted: [:], foundAt: date, defaultEngine: .webKit)
        #expect(plan.sidebar.personas == [home, work])
        for persona in [home, work] {
            #expect(plan.sidebar.favorites.filter { $0.resolvedPersonaID == persona.id } == favorites.filter { $0.resolvedPersonaID == persona.id })
        }
        #expect(plan.repairs.isEmpty && plan.recordsToDelete.isEmpty)
    }

    @Test func aLegacyPersonaHasNoIncomingLayoutAndAnEmptyLayoutStaysExplicit() throws {
        let space = Space(name: "Personal")
        let date = Date(timeIntervalSinceReferenceDate: 30)
        func mapped(_ rows: [Int]?) throws -> Persona {
            let persona = Persona(id: Persona.defaultID, name: "Home", favoriteRows: rows)
            let state = SidebarSyncState(personas: [persona], spaces: [space], folders: [], favorites: [], pinnedTabs: [])
            let records = try SidebarRecords.records(from: state, foundAt: date)
            let record = try #require(records.first { $0.recordType == .persona })
            #expect((record[.favoriteRows] == nil) == (rows == nil))
            let plan = try IncomingSidebarRecords.plan(records: records, deleted: [:], foundAt: date, defaultEngine: .webKit)
            return try #require(plan.sidebar.personas.first)
        }
        #expect(try mapped(nil).favoriteRows == nil)
        #expect(try mapped([]).favoriteRows == [])
    }

    @Test(arguments: [SyncValue.text("not JSON"), .text("[1,\"two\"]"), .number(2)])
    func anUnreadableFavoriteLayoutWaitsWithItsPersona(_ value: SyncValue) throws {
        let persona = Persona(name: "Work", favoriteRows: [1, 2])
        let space = Space(name: "Projects", personaID: persona.id)
        let date = Date(timeIntervalSinceReferenceDate: 30)
        let state = SidebarSyncState(personas: [persona], spaces: [space], folders: [], favorites: [], pinnedTabs: [])
        var records = try SidebarRecords.records(from: state, foundAt: date)
        records[0][.favoriteRows] = value
        #expect(IncomingSidebarRecords.heldOut(server: records, local: []) == [persona.id.uuidString, space.id.uuidString])
        let plan = try IncomingSidebarRecords.plan(records: records, deleted: [:], foundAt: date, defaultEngine: .webKit)
        #expect(!plan.sidebar.personas.contains { $0.id == persona.id })
        #expect(plan.repairs.isEmpty && plan.recordsToDelete.isEmpty)
    }

    /// A folder's color syncs as encrypted text in `tint` and returns through the incoming mapping; clearing it removes the field.
    @Test func aFoldersTintRoundTripsAndClearingItRemovesTheField() throws {
        let space = Space(name: "One")
        var folder = TabFolder(spaceID: space.id, name: "News", isPinned: true)
        folder.tint = .purple
        func records(_ folder: TabFolder, at date: Date) throws -> [SyncRecord] {
            let snapshot = SessionSnapshot(personas: [Persona(id: Persona.defaultID, name: "Home")], spaces: [space], currentSpaceID: space.id,
                                           favorites: [], tabs: [], folders: [folder])
            return try SidebarRecords.records(from: SidebarSyncState(snapshot: snapshot, defaultEngine: .webKit), foundAt: date)
        }
        let date = Date(timeIntervalSinceReferenceDate: 30)
        let sent = try records(folder, at: date)
        let item = try #require(sent.first { $0.recordType == .folder })
        #expect(item[.tint] == .text("purple"))
        let ckRecord = SyncCloudKitRecords.ckRecord(from: item)
        #expect(ckRecord.encryptedValues["tint"] as? String == "purple" && ckRecord["tint"] == nil)
        let fetched = try #require(SyncCloudKitRecords.syncRecord(from: ckRecord))
        let plan = try IncomingSidebarRecords.plan(records: sent.map { $0.recordName == item.recordName ? fetched : $0 }, deleted: [:], foundAt: date, defaultEngine: .webKit)
        #expect(plan.sidebar.folders.map(\.tint) == [.purple])
        folder.tint = nil
        let later = date.addingTimeInterval(60)
        let cleared = SyncDiff.changes(local: try records(folder, at: later), scope: { $0.recordType != .setting }, mirror: sent, pending: [], foundAt: later)
        #expect(cleared.saves.count == 1 && cleared.saves.first?[.tint] == nil)
        let clearedRecord = try #require(cleared.saves.first)
        #expect(clearedRecord.fieldModifiedAt["tint"] == later)
        let clearedCloud = SyncCloudKitRecords.ckRecord(from: clearedRecord, base: ckRecord)
        #expect(clearedCloud.encryptedValues["tint"] == nil && clearedCloud["tint"] == nil)
        let clearedFetched = try #require(SyncCloudKitRecords.syncRecord(from: clearedCloud))
        let clearedPlan = try IncomingSidebarRecords.plan(records: sent.map { $0.recordName == item.recordName ? clearedFetched : $0 }, deleted: [:], foundAt: later, defaultEngine: .webKit)
        #expect(clearedPlan.sidebar.folders.map(\.tint) == [nil])
    }

    /// Live folders were removed, so this build neither writes nor clears a folder's `live` field: an older Mac's live folder keeps it on the server through this Mac's edits (`docs/sync.md`, Schema versions).
    @Test func aFoldersLiveFieldFromAnOlderMacStaysThroughEdits() throws {
        let space = Space(name: "One")
        var folder = TabFolder(spaceID: space.id, name: "News", isPinned: true)
        func records(_ folder: TabFolder, at date: Date) throws -> [SyncRecord] {
            let snapshot = SessionSnapshot(spaces: [space], currentSpaceID: space.id, favorites: [], tabs: [], folders: [folder])
            return try SidebarRecords.records(from: SidebarSyncState(snapshot: snapshot, defaultEngine: .webKit), foundAt: date)
        }
        let date = Date(timeIntervalSinceReferenceDate: 30)
        var mirror = try records(folder, at: date)
        let index = try #require(mirror.firstIndex { $0.recordName == folder.id.uuidString })
        mirror[index].fields["live"] = .text("older configuration")
        mirror[index].fieldModifiedAt["live"] = date
        let later = date.addingTimeInterval(90)
        let same = SyncDiff.changes(local: try records(folder, at: later), scope: { $0.recordType != .setting }, mirror: mirror, pending: [], foundAt: later)
        #expect(same.saves.isEmpty && same.deletions.isEmpty)
        folder.name = "Reading"
        let renamed = SyncDiff.changes(local: try records(folder, at: later), scope: { $0.recordType != .setting }, mirror: mirror, pending: [], foundAt: later)
        let save = try #require(renamed.saves.first)
        #expect(renamed.saves.count == 1 && save[.name] == .text("Reading") && save.fields["live"] == .text("older configuration"))
        let cloud = SyncCloudKitRecords.ckRecord(from: save, base: SyncCloudKitRecords.ckRecord(from: mirror[index]))
        #expect(cloud.encryptedValues["live"] as? String == "older configuration")
    }
}
