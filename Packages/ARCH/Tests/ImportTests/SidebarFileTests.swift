// A synthetic `StorableSidebar.json`: spaces on two profile references and a missing profile folder, their pinned tabs and folders, and each profile's favorites; spaces that name their containers only in `newContainerIDs`, or name no pinned container.
import Foundation
import Testing
@testable import Import

@Suite struct SidebarFileTests {
    @Test func spacesAndFavoritesComeInByProfileFolder() throws {
        let items = SidebarItems.flat([
            SidebarItems.container("pinned-home", ["one", "work", "split", "local-file", "unknown"]),
            SidebarItems.tab("one", "https://one.example/", savedTitle: "One", title: "My One"),
            SidebarItems.item("work", "list", title: "Work", ["two", "docs"]),
            SidebarItems.tab("two", "https://two.example/", savedTitle: "Two"),
            SidebarItems.item("docs", "list", title: "Docs", ["three"]),
            SidebarItems.tab("three", "https://three.example/", savedTitle: "Three"),
            SidebarItems.item("split", "splitView", ["four", "five"]),
            SidebarItems.tab("four", "https://four.example/", savedTitle: "Four"),
            SidebarItems.tab("five", "https://five.example/", savedTitle: "Five"),
            SidebarItems.tab("local-file", "file:///tmp/page.html", savedTitle: "File"),
            SidebarItems.item("unknown", "someFutureKind", ["one"]),
            SidebarItems.container("unpinned-home", ["today"]),
            SidebarItems.tab("today", "https://today.example/", savedTitle: "Today"),
            SidebarItems.container("pinned-work", ["seven"]),
            SidebarItems.tab("seven", "https://seven.example/", savedTitle: "Seven"),
            SidebarItems.container("unpinned-work", []),
            SidebarItems.container("pinned-elsewhere", ["eight"]),
            SidebarItems.tab("eight", "https://eight.example/", savedTitle: "Eight"),
            SidebarItems.container("favorites-default", ["named", "untitled"]),
            SidebarItems.tab("named", "https://named.example/", savedTitle: "Page", title: "Named"),
            SidebarItems.tab("untitled", "https://untitled.example/", savedTitle: "Untitled Page"),
            SidebarItems.container("favorites-work", ["work-favorite"]),
            SidebarItems.tab("work-favorite", "https://work.example/", savedTitle: "Work Page"),
        ])
        let spaces = SidebarItems.flat([
            SidebarItems.space("home", title: "Home", profile: SidebarItems.defaultProfile, pinned: "pinned-home", unpinned: "unpinned-home", theme: ["red": 0.2, "green": 0.4, "blue": 0.9]),
            SidebarItems.space("work-space", title: nil, profile: SidebarItems.customProfile("Profile 2"), pinned: "pinned-work", unpinned: "unpinned-work"),
            SidebarItems.space("elsewhere", title: "Elsewhere", profile: SidebarItems.customProfile("Profile 9"), pinned: "pinned-elsewhere", unpinned: "unpinned-work"),
        ])
        let topApps: [Any] = [SidebarItems.defaultProfile, "favorites-default", SidebarItems.customProfile("Profile 2"), "favorites-work"]
        let data = try SidebarItems.file(version: 2, containers: [["global": [String: Any]()], ["items": items, "spaces": spaces, "topAppsContainerIDs": topApps]])

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
        #expect(home.folders.map(\.name) == ["Work", "Work \u{25B8} Docs"])
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
        #expect(SidebarFile(data: try SidebarItems.file(containers: [["global": [String: Any]()]])) == nil)
        #expect(SidebarFile(data: Data("[]".utf8)) == nil)
    }

    @Test func aFolderInsideItselfEndsTheWalk() throws {
        let items = SidebarItems.flat([
            SidebarItems.container("pinned", ["loop"]),
            SidebarItems.item("loop", "list", title: "Loop", ["loop", "tab"]),
            SidebarItems.tab("tab", "https://tab.example/", savedTitle: "Tab"),
        ])
        let spaces = SidebarItems.flat([SidebarItems.space("space", title: "Space", profile: SidebarItems.defaultProfile, pinned: "pinned", unpinned: "none")])
        let data = try SidebarItems.file(containers: [["items": items, "spaces": spaces]])
        let space = try #require(SidebarFile(data: data)?.profiles.first?.spaces.first)
        #expect(space.folders.map(\.name) == ["Loop"])
        #expect(space.folders.map { $0.items.map(\.title) } == [["Tab"]])
    }

    @Test func labelObjectsNameThePinnedContainerWithoutTheLabelStrings() throws {
        let items = SidebarItems.flat([
            SidebarItems.container("pinned", ["tab"]),
            SidebarItems.tab("tab", "https://tab.example/", savedTitle: "Tab"),
            SidebarItems.container("unpinned", ["today"]),
            SidebarItems.tab("today", "https://today.example/", savedTitle: "Today"),
        ])
        var space = SidebarItems.space("space", title: "Space", profile: SidebarItems.defaultProfile, pinned: "pinned", unpinned: "unpinned")
        space["containerIDs"] = nil
        space["newContainerIDs"] = [["unpinned": ["_0": [String: Any]()]], "unpinned", ["pinned": [String: Any]()], "pinned"]
        let data = try SidebarItems.file(containers: [["items": items, "spaces": SidebarItems.flat([space])]])
        let read = try #require(SidebarFile(data: data)?.profiles.first?.spaces.first)
        #expect(read.pinnedItems.map(\.title) == ["Tab"])
    }

    @Test func spacesWithoutAPinnedContainerCannotBeRead() throws {
        var space = SidebarItems.space("space", title: "Space", profile: SidebarItems.defaultProfile, pinned: "pinned", unpinned: "unpinned")
        space["containerIDs"] = ["unpinned", "unpinned"]
        let data = try SidebarItems.file(containers: [["items": SidebarItems.flat([SidebarItems.container("pinned", [])]), "spaces": SidebarItems.flat([space])]])
        #expect(SidebarFile(data: data) == nil)
    }
}
