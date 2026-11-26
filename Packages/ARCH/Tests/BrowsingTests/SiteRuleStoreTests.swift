import Combine
import Foundation
import Testing
@testable import Browsing

@Suite struct SiteRuleStoreTests {
    private func rule(_ host: String = "example.com", path: String = "") -> SiteRule {
        SiteRule(host: host, pathPrefix: path, spaceID: UUID(), personaID: UUID(), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func rulesRoundTripWithPrivatePermissionsAndNormalizedSites() throws {
        let folder = try SiteRuleTestFolder()
        let store = SiteRuleStore(directory: folder.url)
        var rule = rule("EXAMPLE.COM.", path: "/Work/")
        rule.window = .newWindow
        try store.save(rule)
        let saved = try #require(store.rules.first)
        #expect(saved.host == "example.com")
        #expect(saved.pathPrefix == "/Work")
        #expect(saved.id == rule.id)
        #expect(saved.modifiedAt == rule.modifiedAt)
        #expect(SiteRuleStore(directory: folder.url).rules == [saved])
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.file)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let rows = try #require(json["rules"] as? [[String: Any]])
        #expect(rows.first?["window"] as? String == "newWindow")
    }

    @Test func duplicateSitesAreRefusedButTheExistingRuleCanChangeDestination() throws {
        let folder = try SiteRuleTestFolder()
        let store = SiteRuleStore(directory: folder.url)
        let existing = rule(path: "/work")
        try store.save(existing)
        let duplicate = rule("EXAMPLE.COM.", path: "/work/")
        #expect(throws: SiteRuleStore.Error.duplicateSite(existing.id)) { try store.save(duplicate) }
        #expect(store.rules == [existing])
        var edited = existing
        edited.spaceID = UUID()
        edited.personaID = UUID()
        edited.window = .newWindow
        try store.save(edited)
        #expect(store.rules == [edited])
        #expect(SiteRuleStore(directory: folder.url).rules == [edited])
        try store.save(rule(path: "/personal"))
        #expect(store.rules.count == 2)
    }

    @Test func removingARuleIsDurable() throws {
        let folder = try SiteRuleTestFolder()
        let store = SiteRuleStore(directory: folder.url)
        let first = rule()
        let second = rule("other.example")
        try store.save(first)
        try store.save(second)
        #expect(store.remove(id: first.id))
        #expect(store.rules == [second])
        #expect(SiteRuleStore(directory: folder.url).rules == [second])
    }

    @Test func aLaterVersionCannotBeReplacedEvenIfItsRowsDoNotDecode() throws {
        let folder = try SiteRuleTestFolder()
        let bytes = Data(#"{"version":2,"rules":{"newLayout":"preserved"}}"#.utf8)
        try bytes.write(to: folder.file)
        let store = SiteRuleStore(directory: folder.url)
        #expect(store.isReadOnly)
        #expect(store.rules.isEmpty)
        #expect(throws: SiteRuleStore.Error.readOnly) { try store.save(rule()) }
        #expect(throws: SiteRuleStore.Error.readOnly) { try store.replaceFromSync([rule()]) }
        #expect(!store.remove(id: UUID()))
        #expect(try Data(contentsOf: folder.file) == bytes)
    }

    @Test func anUnreadableFileIsPreservedAtTheFirstEdit() throws {
        let folder = try SiteRuleTestFolder()
        let bytes = Data("{".utf8)
        try bytes.write(to: folder.file)
        let store = SiteRuleStore(directory: folder.url)
        #expect(!store.isReadOnly)
        #expect(store.rules.isEmpty)
        #expect(try Data(contentsOf: folder.file) == bytes)
        let rule = rule()
        try store.save(rule)
        #expect(try Data(contentsOf: folder.url.appendingPathComponent("site-rules.unreadable.json")) == bytes)
        #expect(SiteRuleStore(directory: folder.url).rules == [rule])
    }

    @Test func syncReplacementIsDurableAndSignalsOnlyAfterWriting() throws {
        let folder = try SiteRuleTestFolder()
        let store = SiteRuleStore(directory: folder.url)
        var observed: [[SiteRule]] = []
        let subscription = store.didChange.sink { observed.append(SiteRuleStore(directory: folder.url).rules) }
        defer { subscription.cancel() }
        let first = rule()
        let second = rule("other.example")
        try store.replaceFromSync([first, second])
        #expect(store.rules == [first, second])
        #expect(observed == [[first, second]])
        try store.replaceFromSync([first, second])
        #expect(observed.count == 1)
        try store.replaceFromSync([])
        #expect(observed == [[first, second], []])
    }

    @Test func failedWritesDoNotChangeTheRulesOrPublishAnEdit() throws {
        let folder = try SiteRuleTestFolder()
        let unusable = folder.url.appendingPathComponent("not-a-directory")
        let store = SiteRuleStore(directory: unusable)
        try Data("file".utf8).write(to: unusable)
        var edits = 0
        let subscription = store.didChange.sink { edits += 1 }
        defer { subscription.cancel() }
        #expect(throws: (any Error).self) { try store.save(rule()) }
        #expect(store.rules.isEmpty)
        #expect(edits == 0)
    }
}

private final class SiteRuleTestFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSiteRuleStoreTests-\(UUID().uuidString)", isDirectory: true)
    var file: URL { url.appendingPathComponent("site-rules.json") }

    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}
