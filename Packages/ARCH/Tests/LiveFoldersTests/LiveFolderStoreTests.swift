// `live-folders.json` in temporary folders and private feed addresses in the in-memory Keychain store (docs/bookmarks.md, Tests ▸ LiveFoldersTests).
import Foundation
import Testing
@testable import LiveFolders

private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

@MainActor
@Suite struct LiveFolderStoreTests {
    @Test func roundTrip() throws {
        let file = try temporaryDirectory().appendingPathComponent(LiveFolderStore.fileName)
        let store = LiveFolderStore(fileURL: file)
        let folder = UUID()
        store.update(folder) { state in
            state.source = .gitHub(search: GitHubSearch(kind: .myPullRequests))
            state.lastAttempt = date
            state.recordSuccess(items: [item("a", gitHub: pullRequest), item("b", date: date)], validators: FeedValidators(entityTag: "\"1\""), feedTitle: "Title", feedInterval: 3_600, at: date)
            state.dismiss("b")
            state.recordFailure(.httpStatus(503, retryAfter: date + 60), at: date)
        }
        store.saveNow()
        let reloaded = LiveFolderStore(fileURL: file)
        #expect(!reloaded.replacedUnreadableFile)
        #expect(reloaded.folders == store.folders)
        #expect(reloaded[folder].items.map(\.id) == ["a", "b"])
        #expect(reloaded[folder].dismissed == ["b"])
        #expect(reloaded[folder].earliestNextAttempt == date + 60)
        #expect(reloaded[UUID()] == LiveFolderState())
    }

    @Test func movesAnUnreadableFileAside() throws {
        let folder = try temporaryDirectory()
        let file = folder.appendingPathComponent(LiveFolderStore.fileName)
        try Data("{ not json".utf8).write(to: file)
        let store = LiveFolderStore(fileURL: file)
        #expect(store.replacedUnreadableFile)
        #expect(store.folders.isEmpty)
        #expect(try String(contentsOf: folder.appendingPathComponent("live-folders.unreadable.json"), encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// An entry that this build cannot decode, as one with a source that a later build adds, stays in the file as it was beside the entries that decode, through other folders' changes, until its folder goes.
    @Test func keepsAnEntryItCannotDecodeAsTheFileHasIt() throws {
        let file = try temporaryDirectory().appendingPathComponent(LiveFolderStore.fileName)
        let known = UUID(), later = UUID()
        let laterEntry = #"{"source": {"laterSource": {"query": "x"}}, "failureCount": 2, "dismissed": ["a"], "viewedAt": {"a": 800000000.5}, "laterField": [1, true, null, "x"]}"#
        let store = LiveFolderStore(fileURL: file)
        store.update(known) { $0.dismiss("b") }
        store.saveNow()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var folders = try #require(json["folders"] as? [String: Any])
        folders[later.uuidString] = try JSONSerialization.jsonObject(with: Data(laterEntry.utf8))
        json["folders"] = folders
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        let reloaded = LiveFolderStore(fileURL: file)
        #expect(!reloaded.replacedUnreadableFile)
        #expect(Set(reloaded.folders.keys) == [known] && reloaded.folderIDs == [known, later])
        #expect(reloaded[known].dismissed == ["b"] && reloaded[later] == LiveFolderState())
        reloaded.update(known) { $0.dismiss("c") }
        reloaded.saveNow()
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let entry = try #require((written["folders"] as? [String: Any])?[later.uuidString] as? NSDictionary)
        #expect(entry == (try JSONSerialization.jsonObject(with: Data(laterEntry.utf8)) as? NSDictionary))
        #expect(LiveFolderStore(fileURL: file)[known].dismissed == ["b", "c"])

        reloaded.removeFolders(notIn: [known])
        reloaded.saveNow()
        #expect(LiveFolderStore(fileURL: file).folderIDs == [known])
        reloaded.update(later) { $0.dismiss("d") }
        reloaded.remove(later)
        #expect(reloaded.folderIDs == [known])
    }

    @Test func dropsTheEntriesOfFoldersThatAreNoLiveFolders() throws {
        let store = LiveFolderStore(fileURL: try temporaryDirectory().appendingPathComponent(LiveFolderStore.fileName))
        let kept = UUID(), removed = UUID()
        store.update(kept) { $0.lastAttempt = date }
        store.update(removed) { $0.lastAttempt = date }
        store.removeFolders(notIn: [kept])
        #expect(Set(store.folders.keys) == [kept])
        store.remove(kept)
        #expect(store.folders.isEmpty)
    }

    @Test func aSuccessPrunesTheReadStateAndDismissalsOfItemsNoLongerListed() {
        var state = LiveFolderState()
        state.recordSuccess(items: [item("a"), item("b"), item("c")], at: date)
        state.dismiss("b")
        state.recordSuccess(items: [item("a"), item("d")], at: date + 60)
        #expect(Set(state.viewedAt.keys) == ["a"])
        #expect(state.dismissed.isEmpty)
        #expect(state.items.map(\.id) == ["a", "d"])
        #expect(state.firstSuccess == date)
        #expect(state.lastSuccess == date + 60)
    }

    @Test func anAnswerThatWithholdsResultsKeepsTheReadStateAndDismissalsOfTheItemsItLeavesOut() {
        var state = LiveFolderState()
        state.recordSuccess(items: [item("a"), item("b"), item("c")], at: date)
        state.dismiss("b")
        state.recordSuccess(items: [item("a")], isComplete: false, at: date + 60)
        #expect(state.items.map(\.id) == ["a"])
        #expect(Set(state.viewedAt.keys) == ["a", "b", "c"])
        #expect(state.dismissed == ["b"])
        // The withheld items return still read and dismissed.
        state.recordSuccess(items: [item("a"), item("b"), item("c")], at: date + 120)
        #expect(state.unreadItemIDs.isEmpty)
        #expect(state.dismissed == ["b"])
    }
}

@Suite struct LiveFolderKeychainTests {
    @Test func setsReadsAndRemovesAddresses() async throws {
        let keychain = InMemoryLiveFolderKeychain()
        let first = UUID(), second = UUID()
        let address = URL(string: "https://tracker.example.org/feed.atom?token=abc123")!
        #expect(try await keychain.address(for: first) == nil)
        try await keychain.setAddress(address, for: first, folderName: "Tracker")
        try await keychain.setAddress(URL(string: "https://other.example.org/feed?key=1")!, for: second, folderName: "Other")
        #expect(try await keychain.address(for: first) == address)
        #expect(keychain.label(for: first) == "Arch Live Folder: Tracker")
        try await keychain.removeAddress(for: first)
        #expect(try await keychain.address(for: first) == nil)
        #expect(keychain.folders == [second])
    }
}
