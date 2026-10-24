// Loading `session.json`: files of each version gain what they lack through `normalized()`, and files this build cannot read or fully understand stay on disk.
import Foundation
import Testing
@testable import Browsing

@Suite struct SessionSnapshotTests {
    @Test(arguments: [1, 4, 7])
    func olderFilesLoadWithAnIDForEveryTabRecord(version: Int) throws {
        let folder = try SessionFolder()
        try folder.write(try #require(olderFiles[version]))
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.spaces.map(\.id) == [spaceA, spaceB])
        #expect(snapshot.currentSpaceID == spaceB)
        #expect(snapshot.favorites.map(\.id) == [favoriteID])
        #expect(snapshot.tabs.map(\.url) == ["a", "b", "c"].map { URL(string: "https://example.org/\($0)") })
        #expect(snapshot.tabs.map(\.spaceID) == [spaceA, spaceA, spaceB])
        #expect(snapshot.selectedTabIndex == 2)
        #expect(snapshot.closedTabs?.map(\.url) == [URL(string: "https://example.org/closed")])
        let ids = snapshot.allTabIDs
        #expect(!ids.contains(nil))
        #expect(Set(ids).count == ids.count)
    }

    @Test func version4FilesKeepTheirEnginesNamesAndHomePages() throws {
        let folder = try SessionFolder()
        try folder.write(version4File)
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.spaces.map(\.homeURL) == [URL(string: "https://example.org/home"), nil])
        #expect(snapshot.tabs.map(\.engine) == [.chromium, .webKit, .chromium])
        #expect(snapshot.tabs.map(\.customTitle) == ["Renamed", nil, nil])
        #expect(snapshot.tabs[0].state == Data([0, 1]))
    }

    @Test func version7FilesGiveTheFavoritesTabAnID() throws {
        let folder = try SessionFolder()
        try folder.write(version7File)
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.favoriteTabs?.map(\.favoriteID) == [favoriteID])
        #expect(snapshot.favoriteTabs?.first?.id != nil)
        #expect(snapshot.splitViews == [[0, 1]])
    }

    @Test func savedIDsLoadUnchanged() throws {
        let folder = try SessionFolder()
        try folder.write(version8File)
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.allTabIDs == [tab1, tab2, tab3, favoriteTab, closedTab])
    }

    @Test func repeatedIDsAreReplacedAfterTheirFirstUse() throws {
        let folder = try SessionFolder()
        try folder.write(version8File.replacingOccurrences(of: tab3.uuidString, with: tab1.uuidString)
            .replacingOccurrences(of: favoriteTab.uuidString, with: tab1.uuidString)
            .replacingOccurrences(of: closedTab.uuidString, with: tab2.uuidString))
        let snapshot = try #require(folder.store.load())
        let ids = snapshot.allTabIDs.compactMap { $0 }
        #expect(ids.count == 5)
        #expect(Set(ids).count == 5)
        #expect(Array(ids.prefix(2)) == [tab1, tab2])
    }

    @Test func savedSnapshotsLoadWithTheSameIDs() throws {
        let folder = try SessionFolder()
        try folder.write(version7File)
        let loaded = try #require(folder.store.load())
        folder.store.saveNow(loaded)
        let reloaded = try #require(folder.store.load())
        #expect(!loaded.allTabIDs.contains(nil))
        #expect(reloaded.allTabIDs == loaded.allTabIDs)
    }

    @Test func newerFilesLeaveACopyAndStillLoad() throws {
        let folder = try SessionFolder()
        let newer = version8File.replacingOccurrences(of: #""version": 8,"#, with: #""version": 99, "laterField": [1, 2],"#)
        try folder.write("an older copy", to: "session-v99.json")
        try folder.write(newer)
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.tabs.count == 3)
        #expect(try folder.contents(of: "session-v99.json") == Data(newer.utf8))
        #expect(try folder.contents(of: "session.json") == Data(newer.utf8))
    }

    @Test func currentFilesLeaveNoCopy() throws {
        let folder = try SessionFolder()
        try folder.write(version8File)
        _ = try #require(folder.store.load())
        #expect(try folder.fileNames() == ["session.json"])
    }

    @Test func unreadableFilesMoveAside() throws {
        let folder = try SessionFolder()
        let unreadable = version8File + "x"
        try folder.write("an older unreadable file", to: "session.unreadable.json")
        try folder.write(unreadable)
        #expect(folder.store.load() == nil)
        #expect(try folder.fileNames() == ["session.unreadable.json"])
        #expect(try folder.contents(of: "session.unreadable.json") == Data(unreadable.utf8))
    }

    @Test func aMissingFileLoadsNothing() throws {
        let folder = try SessionFolder()
        #expect(folder.store.load() == nil)
        #expect(try folder.fileNames().isEmpty)
    }
}

/// A folder of its own for one test's files, removed when the test ends.
private final class SessionFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchBrowsingTests-\(UUID().uuidString)", isDirectory: true)
    var store: SessionStore { SessionStore(directory: url) }

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ text: String, to name: String = "session.json") throws {
        try Data(text.utf8).write(to: url.appendingPathComponent(name))
    }

    func contents(of name: String) throws -> Data {
        try Data(contentsOf: url.appendingPathComponent(name))
    }

    func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

private extension SessionSnapshot {
    /// The IDs of the open tabs, the favorites' tabs, and the closed tabs, in that order.
    var allTabIDs: [UUID?] {
        tabs.map(\.id) + (favoriteTabs ?? []).map(\.id) + (closedTabs ?? []).map(\.id)
    }
}

private let spaceA = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F01")!
private let spaceB = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F02")!
private let favoriteID = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F03")!
private let tab1 = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F11")!
private let tab2 = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F12")!
private let tab3 = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F13")!
private let favoriteTab = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F14")!
private let closedTab = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F15")!

/// The files without tab IDs, by version.
private let olderFiles = [1: version1File, 4: version4File, 7: version7File]

/// A file without a version: no engines, page states, or home pages.
private let version1File = """
{
  "spaces": [
    { "id": "\(spaceA)", "name": "Personal", "symbol": "circle.fill", "tint": "blue" },
    { "id": "\(spaceB)", "name": "Work", "symbol": "briefcase.fill", "tint": "green" }
  ],
  "currentSpaceID": "\(spaceB)",
  "favorites": [ { "id": "\(favoriteID)", "url": "https://example.com", "title": "Example" } ],
  "tabs": [
    { "spaceID": "\(spaceA)", "url": "https://example.org/a", "title": "A", "isPinned": true },
    { "spaceID": "\(spaceA)", "url": "https://example.org/b", "title": "B", "isPinned": false },
    { "spaceID": "\(spaceB)", "url": "https://example.org/c", "title": "C", "isPinned": false }
  ],
  "selectedTabIndex": 2,
  "closedTabs": [ { "spaceID": "\(spaceA)", "url": "https://example.org/closed", "title": "Closed", "isPinned": false } ]
}
"""

/// A version 4 file: engines, page states, a renamed tab, and a home page.
private let version4File = """
{
  "version": 4,
  "spaces": [
    { "id": "\(spaceA)", "name": "Personal", "symbol": "circle.fill", "tint": "blue", "homeURL": "https://example.org/home" },
    { "id": "\(spaceB)", "name": "Work", "symbol": "briefcase.fill", "tint": "green" }
  ],
  "currentSpaceID": "\(spaceB)",
  "favorites": [ { "id": "\(favoriteID)", "url": "https://example.com", "title": "Example" } ],
  "tabs": [
    { "spaceID": "\(spaceA)", "url": "https://example.org/a", "title": "A", "customTitle": "Renamed", "isPinned": true, "lastActivatedAt": 790000000, "engine": "chromium", "state": "AAE=" },
    { "spaceID": "\(spaceA)", "url": "https://example.org/b", "title": "B", "isPinned": false, "lastActivatedAt": 790000100, "engine": "webKit" },
    { "spaceID": "\(spaceB)", "url": "https://example.org/c", "title": "C", "isPinned": false, "lastActivatedAt": 790000200, "engine": "chromium" }
  ],
  "selectedTabIndex": 2,
  "closedTabs": [ { "spaceID": "\(spaceA)", "url": "https://example.org/closed", "title": "Closed", "isPinned": false, "engine": "webKit" } ]
}
"""

/// A version 7 file: a favorite's tab, folders, and a split view.
private let version7File = """
{
  "version": 7,
  "spaces": [
    { "id": "\(spaceA)", "name": "Personal", "symbol": "circle.fill", "tint": "blue" },
    { "id": "\(spaceB)", "name": "Work", "symbol": "briefcase.fill", "tint": "green" }
  ],
  "currentSpaceID": "\(spaceB)",
  "favorites": [ { "id": "\(favoriteID)", "url": "https://example.com", "title": "Example" } ],
  "tabs": [
    { "spaceID": "\(spaceA)", "url": "https://example.org/a", "title": "A", "isPinned": true, "engine": "chromium" },
    { "spaceID": "\(spaceA)", "url": "https://example.org/b", "title": "B", "isPinned": false, "engine": "chromium" },
    { "spaceID": "\(spaceB)", "url": "https://example.org/c", "title": "C", "isPinned": false, "engine": "webKit" }
  ],
  "folders": [],
  "selectedTabIndex": 2,
  "closedTabs": [ { "spaceID": "\(spaceA)", "url": "https://example.org/closed", "title": "Closed", "isPinned": false, "engine": "chromium" } ],
  "splitViews": [[0, 1]],
  "favoriteTabs": [ { "favoriteID": "\(favoriteID)", "url": "https://example.com/page", "engine": "chromium" } ]
}
"""

/// A version 8 file, in which every tab record has its ID.
private let version8File = """
{
  "version": 8,
  "spaces": [
    { "id": "\(spaceA)", "name": "Personal", "symbol": "circle.fill", "tint": "blue" },
    { "id": "\(spaceB)", "name": "Work", "symbol": "briefcase.fill", "tint": "green" }
  ],
  "currentSpaceID": "\(spaceB)",
  "favorites": [ { "id": "\(favoriteID)", "url": "https://example.com", "title": "Example" } ],
  "tabs": [
    { "id": "\(tab1)", "spaceID": "\(spaceA)", "url": "https://example.org/a", "title": "A", "isPinned": true, "engine": "chromium" },
    { "id": "\(tab2)", "spaceID": "\(spaceA)", "url": "https://example.org/b", "title": "B", "isPinned": false, "engine": "chromium" },
    { "id": "\(tab3)", "spaceID": "\(spaceB)", "url": "https://example.org/c", "title": "C", "isPinned": false, "engine": "webKit" }
  ],
  "selectedTabIndex": 2,
  "closedTabs": [ { "id": "\(closedTab)", "spaceID": "\(spaceA)", "url": "https://example.org/closed", "title": "Closed", "isPinned": false, "engine": "chromium" } ],
  "favoriteTabs": [ { "id": "\(favoriteTab)", "favoriteID": "\(favoriteID)", "url": "https://example.com/page", "engine": "chromium" } ]
}
"""
