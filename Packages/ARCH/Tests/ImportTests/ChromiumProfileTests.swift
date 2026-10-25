// Chromium-format profiles over a synthetic user data folder: the profile list from `Local State`, with a missing `last_used` and a file that cannot be read, and a profile's two bookmark files.
import Foundation
import Testing
@testable import Import

@Suite struct ChromiumProfileTests {
    @Test func localStateListsItsProfilesInOrder() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.writeJSON(["profile": [
            "info_cache": ["Default": ["name": "Personal"], "Profile 2": ["name": "Work"], "Profile 3": ["name": ""]],
            "profiles_order": ["Profile 2", "Default", "Profile 7"],
            "last_used": "Default",
        ]], to: "Local State")
        let profiles = try ChromiumProfile.profiles(in: folder.url)
        #expect(profiles.map(\.folder.lastPathComponent) == ["Profile 2", "Default", "Profile 3"])
        #expect(profiles.map(\.name) == ["Work", "Personal", "Profile 3"])
        #expect(profiles.map(\.isLastUsed) == [false, true, false])
    }

    @Test func aFolderWithoutLocalStateHasTheDefaultProfileAlone() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let profiles = try ChromiumProfile.profiles(in: folder.url)
        #expect(profiles == [ChromiumProfile(folder: folder.url.appendingPathComponent("Default"), name: "Default", isLastUsed: true)])
    }

    @Test func withoutALastUsedProfileTheDefaultOneIsLastUsed() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.writeJSON(["profile": ["info_cache": ["Default": ["name": "Personal"], "Profile 1": ["name": "Work"]]]], to: "Local State")
        let profiles = try ChromiumProfile.profiles(in: folder.url)
        #expect(profiles.map(\.folder.lastPathComponent) == ["Default", "Profile 1"])
        #expect(profiles.map(\.isLastUsed) == [true, false])
    }

    @Test func aLocalStateThatDoesNotListProfilesIsReportedByName() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.write(Data("{".utf8), to: "Local State")
        #expect(throws: ImportError.unreadableFile(file)) { try ChromiumProfile.profiles(in: folder.url) }
        try folder.writeJSON(["profile": ["last_used": "Profile 1"]], to: "Local State")
        #expect(throws: ImportError.unreadableFile(file)) { try ChromiumProfile.profiles(in: folder.url) }
    }

    @Test func accountBookmarksFollowTheProfileBookmarksAndRepeatNoAddress() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.writeJSON(ChromiumBookmarks.file(
            bar: [ChromiumBookmarks.url("a", "A", "https://a.example/"), ChromiumBookmarks.folder("work", "Work", [ChromiumBookmarks.url("b", "B", "https://b.example/")])],
            other: [ChromiumBookmarks.url("d", "D", "https://d.example/")]
        ), to: "Default/Bookmarks")
        try folder.writeJSON(ChromiumBookmarks.file(
            bar: [ChromiumBookmarks.url("a2", "A again", "https://a.example/"), ChromiumBookmarks.url("k", "K", "https://k.example/"),
                  ChromiumBookmarks.folder("trips", "Trips", [ChromiumBookmarks.url("t", "T", "https://t.example/"), ChromiumBookmarks.url("d2", "D again", "https://d.example/")])],
            other: [ChromiumBookmarks.url("l", "L", "https://l.example/")],
            prefix: "account-"
        ), to: "Default/AccountBookmarks")
        let profile = ChromiumProfile(folder: folder.url.appendingPathComponent("Default"), name: "Default", isLastUsed: true)
        let (barItems, folders) = try #require(try profile.bookmarks()).split()
        #expect(barItems.map(\.sourceID) == ["a", "k"])
        #expect(folders.map(\.name) == ["Work", "Trips", "Other Bookmarks", "Other Bookmarks"])
        #expect(folders.map(\.sourceID) == ["work", "trips", "other", "account-other"])
        #expect(folders.map { $0.items.map(\.sourceID) } == [["b"], ["t"], ["d"], ["l"]])
    }

    @Test func aProfileWithOnlyEncryptedBookmarksCannotBeRead() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let profile = ChromiumProfile(folder: folder.url.appendingPathComponent("Default"), name: "Default", isLastUsed: true)
        #expect(try profile.bookmarks() == nil)
        try folder.write(Data([0x01, 0x02]), to: "Default/EncryptedBookmarks2")
        #expect(throws: ImportError.encryptedBookmarks) { try profile.bookmarks() }
    }

    @Test func aBookmarksFileThatDoesNotParseIsReportedByName() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.write(Data("{".utf8), to: "Default/Bookmarks")
        let profile = ChromiumProfile(folder: file.deletingLastPathComponent(), name: "Default", isLastUsed: true)
        #expect(throws: ImportError.unreadableFile(file)) { try profile.bookmarks() }
    }
}
