// A synthetic `StorableSidebar.json`: spaces on two profile references and a missing profile folder, their pinned tabs and folders, and each profile's favorites; spaces that name their containers only in `newContainerIDs`, or name no pinned container.
import Foundation
import Testing
@testable import Import

@Suite struct SidebarFileTests {
    private static let defaultProfile: [String: Any] = ["default": true]
    private static func customProfile(_ folder: String) -> [String: Any] {
        ["custom": ["_0": ["directoryBasename": folder, "machineID": "machine"]]]
    }

    private static func container(_ id: String, _ children: [String]) -> [String: Any] {
        ["id": id, "parentID": NSNull(), "childrenIds": children, "data": ["itemContainer": ["containerType": ["spaceItems": ["_0": "space"]]]]]
    }

    private static func tab(_ id: String, _ address: String, savedTitle: String, title: String? = nil) -> [String: Any] {
        ["id": id, "title": title ?? NSNull(), "childrenIds": [String](), "data": ["tab": ["savedURL": address, "savedTitle": savedTitle]]]
    }

    private static func item(_ id: String, _ kind: String, title: String? = nil, _ children: [String]) -> [String: Any] {
        ["id": id, "title": title ?? NSNull(), "childrenIds": children, "data": [kind: [String: Any]()]]
    }

    private static func space(_ id: String, title: String?, profile: [String: Any], pinned: String, unpinned: String, theme: [String: Double]? = nil) -> [String: Any] {
        var space: [String: Any] = ["id": id, "containerIDs": ["unpinned", unpinned, "pinned", pinned], "profile": profile]
        space["title"] = title
        space["customInfo"] = theme.map { ["windowTheme": ["primaryColorPalette": ["midTone": $0.merging(["alpha": 1]) { first, _ in first }]]] }
        return space
    }

    /// An array that alternates each object's ID with the object, as the file stores `items` and `spaces`.
    private static func flat(_ objects: [[String: Any]]) -> [Any] {
        objects.flatMap { [$0["id"]!, $0] }
    }

    private static func file(version: Int = 1, containers: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "sidebar": ["containers": containers], "sidebarSyncState": ["containers": [[String: Any]]()]])
    }

    @Test func spacesAndFavoritesComeInByProfileFolder() throws {
        let items = Self.flat([
            Self.container("pinned-home", ["one", "work", "split", "local-file", "unknown"]),
            Self.tab("one", "https://one.example/", savedTitle: "One", title: "My One"),
            Self.item("work", "list", title: "Work", ["two", "docs"]),
            Self.tab("two", "https://two.example/", savedTitle: "Two"),
            Self.item("docs", "list", title: "Docs", ["three"]),
            Self.tab("three", "https://three.example/", savedTitle: "Three"),
            Self.item("split", "splitView", ["four", "five"]),
            Self.tab("four", "https://four.example/", savedTitle: "Four"),
            Self.tab("five", "https://five.example/", savedTitle: "Five"),
            Self.tab("local-file", "file:///tmp/page.html", savedTitle: "File"),
            Self.item("unknown", "someFutureKind", ["one"]),
            Self.container("unpinned-home", ["today"]),
            Self.tab("today", "https://today.example/", savedTitle: "Today"),
            Self.container("pinned-work", ["seven"]),
            Self.tab("seven", "https://seven.example/", savedTitle: "Seven"),
            Self.container("unpinned-work", []),
            Self.container("pinned-elsewhere", ["eight"]),
            Self.tab("eight", "https://eight.example/", savedTitle: "Eight"),
            Self.container("favorites-default", ["named", "untitled"]),
            Self.tab("named", "https://named.example/", savedTitle: "Page", title: "Named"),
            Self.tab("untitled", "https://untitled.example/", savedTitle: "Untitled Page"),
            Self.container("favorites-work", ["work-favorite"]),
            Self.tab("work-favorite", "https://work.example/", savedTitle: "Work Page"),
        ])
        let spaces = Self.flat([
            Self.space("home", title: "Home", profile: Self.defaultProfile, pinned: "pinned-home", unpinned: "unpinned-home", theme: ["red": 0.2, "green": 0.4, "blue": 0.9]),
            Self.space("work-space", title: nil, profile: Self.customProfile("Profile 2"), pinned: "pinned-work", unpinned: "unpinned-work"),
            Self.space("elsewhere", title: "Elsewhere", profile: Self.customProfile("Profile 9"), pinned: "pinned-elsewhere", unpinned: "unpinned-work"),
        ])
        let topApps: [Any] = [Self.defaultProfile, "favorites-default", Self.customProfile("Profile 2"), "favorites-work"]
        let data = try Self.file(version: 2, containers: [["global": [String: Any]()], ["items": items, "spaces": spaces, "topAppsContainerIDs": topApps]])

        let profiles = try #require(SidebarFile(data: data)).profiles
        #expect(profiles.map(\.folderName) == ["Default", "Profile 2", "Profile 9"])

        let home = try #require(profiles[0].spaces.first)
        #expect(profiles[0].spaces.count == 1)
        #expect(home.origin == .space("home"))
        #expect(home.name == "Home")
        #expect(home.tint == .blue)
        #expect(home.pinnedItems.map(\.sourceID) == ["one", "four", "five"])
        #expect(home.pinnedItems.map(\.title) == ["One", "Four", "Five"])
        #expect(home.pinnedItems.map(\.customTitle) == ["My One", nil, nil])
        #expect(home.folders.map(\.name) == ["Work", "Work / Docs"])
        #expect(home.folders.map(\.sourceID) == ["work", "docs"])
        #expect(home.folders.map { $0.items.map(\.title) } == [["Two"], ["Three"]])
        #expect(profiles[0].favorites.map(\.title) == ["Named", "Untitled Page"])
        #expect(profiles[0].favorites.allSatisfy { $0.customTitle == nil })

        let work = try #require(profiles[1].spaces.first)
        #expect(work.name == nil)
        #expect(work.tint == nil)
        #expect(work.pinnedItems.map(\.title) == ["Seven"])
        #expect(profiles[1].favorites.map(\.sourceID) == ["work-favorite"])

        #expect(profiles[2].spaces.map(\.name) == ["Elsewhere"])
        #expect(profiles[2].favorites.isEmpty)
    }

    @Test func aFileWithoutItemsAndSpacesCannotBeRead() throws {
        #expect(SidebarFile(data: try Self.file(containers: [["global": [String: Any]()]])) == nil)
        #expect(SidebarFile(data: Data("[]".utf8)) == nil)
    }

    @Test func aFolderInsideItselfEndsTheWalk() throws {
        let items = Self.flat([
            Self.container("pinned", ["loop"]),
            Self.item("loop", "list", title: "Loop", ["loop", "tab"]),
            Self.tab("tab", "https://tab.example/", savedTitle: "Tab"),
        ])
        let spaces = Self.flat([Self.space("space", title: "Space", profile: Self.defaultProfile, pinned: "pinned", unpinned: "none")])
        let data = try Self.file(containers: [["items": items, "spaces": spaces]])
        let space = try #require(SidebarFile(data: data)?.profiles.first?.spaces.first)
        #expect(space.folders.map(\.name) == ["Loop"])
        #expect(space.folders.map { $0.items.map(\.title) } == [["Tab"]])
    }

    @Test func labelObjectsNameThePinnedContainerWithoutTheLabelStrings() throws {
        let items = Self.flat([
            Self.container("pinned", ["tab"]),
            Self.tab("tab", "https://tab.example/", savedTitle: "Tab"),
            Self.container("unpinned", ["today"]),
            Self.tab("today", "https://today.example/", savedTitle: "Today"),
        ])
        var space = Self.space("space", title: "Space", profile: Self.defaultProfile, pinned: "pinned", unpinned: "unpinned")
        space["containerIDs"] = nil
        space["newContainerIDs"] = [["unpinned": ["_0": [String: Any]()]], "unpinned", ["pinned": [String: Any]()], "pinned"]
        let data = try Self.file(containers: [["items": items, "spaces": Self.flat([space])]])
        let read = try #require(SidebarFile(data: data)?.profiles.first?.spaces.first)
        #expect(read.pinnedItems.map(\.title) == ["Tab"])
    }

    @Test func spacesWithoutAPinnedContainerCannotBeRead() throws {
        var space = Self.space("space", title: "Space", profile: Self.defaultProfile, pinned: "pinned", unpinned: "unpinned")
        space["containerIDs"] = ["unpinned", "unpinned"]
        let data = try Self.file(containers: [["items": Self.flat([Self.container("pinned", [])]), "spaces": Self.flat([space])]])
        #expect(SidebarFile(data: data) == nil)
    }
}
