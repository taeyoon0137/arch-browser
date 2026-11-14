import ARCHEngine
@testable import Browsing
import CloudKit
import Foundation
import LiveFolders
import Sync
import Testing

@Suite struct SidebarRecordsTests {
    @Test func mapsTheSavedSidebarInSiblingOrderWithEncryptedLiveConfiguration() throws {
        let personal = Persona(id: Persona.defaultID, name: "Home"), work = Persona(name: "Work")
        var first = Space(name: "One", symbol: "star", tint: .green, personaID: work.id)
        let second = Space(name: "Two", personaID: work.id)
        let saved = URL(string: "https://example.test/bookmark")!
        first.homeURL = saved
        let ordinary = TabFolder(spaceID: first.id, name: "Outer", isPinned: true)
        let live = LiveFolderConfiguration(source: .feed(address: saved, isPrivate: false), itemLimit: 10, refreshMinutes: 60)
        let nested = TabFolder(spaceID: first.id, name: "News", isPinned: true, parentID: ordinary.id, live: live)
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
        #expect(byName["default"]?.fields == ["name": .text("Home"), "order": .number(1)])
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
        #expect(item.schemaVersion == 2)
        #expect(item[.parent] == .reference(ordinary.id.uuidString))
        #expect(item[.order] == .number(1))
        let cloud = SyncCloudKitRecords.ckRecord(from: item)
        let liveText = try #require(cloud.encryptedValues["live"] as? String)
        #expect(cloud["live"] == nil)
        #expect(try JSONDecoder().decode(LiveFolderConfiguration.self, from: Data(liveText.utf8)) == live)
        let later = date.addingTimeInterval(90)
        let same = try SidebarRecords.records(from: state, foundAt: later)
        let changes = SyncDiff.changes(local: same, scope: { $0.recordType != .setting }, mirror: records, pending: [], foundAt: later)
        #expect(changes.saves.isEmpty && changes.deletions.isEmpty)
    }
}
