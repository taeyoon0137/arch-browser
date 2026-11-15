// The first-sync plan operates on plain records. Page matching uses the browser's actual bookmark rule.
@testable import Browsing
import Foundation
import Sync
import Testing

@Suite struct FirstSyncMergeTests {
    private let now = Date(timeIntervalSinceReferenceDate: 100)
    private func record(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncValue]) -> SyncRecord {
        SyncRecord(recordType: type, recordName: id, fields: fields, modifiedAt: now)
    }
    private func space(_ id: String, _ name: String, persona: String = "default") -> SyncRecord {
        record(.space, id, ["persona": .reference(persona), "name": .text(name)])
    }
    private func folder(_ id: String, _ name: String, space: String, parent: String? = nil) -> SyncRecord {
        var folder = record(.folder, id, ["persona": .reference("default"), "space": .reference(space), "name": .text(name)])
        folder[.parent] = parent.map(SyncValue.reference)
        return folder
    }
    private func tab(_ id: String, space: String, folder: String? = nil, url: String? = nil) -> SyncRecord {
        var tab = record(.tab, id, ["persona": .reference("default"), "space": .reference(space)])
        tab[.folder] = folder.map(SyncValue.reference)
        tab[.url] = url.map(SyncValue.text)
        return tab
    }
    private func plan(_ local: [SyncRecord], _ server: [SyncRecord]) throws -> FirstSyncMerge.Plan {
        try FirstSyncMerge.plan(local: local, server: server) { $0.isSamePage(as: $1) }
    }

    @Test func anEmptyZoneUploadsTheSyncableItemsInSidebarOrder() throws {
        let local = [space("space", "Personal"), tab("tab", space: "space"), record(.setting, "ARCHAppearance", ["value": .text("dark")])]
        let result = try plan(local, [])
        #expect(result.recordsToUpload == local)
        #expect(result.recordsToApply.isEmpty)
        #expect(result.replacements.isEmpty)
    }

    /// Local keys number each list from 1, so an unmatched local item would otherwise sort among the server's items of its list.
    @Test func unmatchedLocalItemsGoAfterTheServersItemsInTheirList() throws {
        func ordered(_ record: SyncRecord, _ key: Double) -> SyncRecord {
            var record = record
            record[.order] = .number(key)
            return record
        }
        let server = [space("space", "Personal")] + (1...3).map { ordered(tab("a\($0)", space: "space"), Double($0)) }
        let local = [space("space", "Personal"), ordered(tab("b2", space: "space"), 2), ordered(tab("b3", space: "space"), 3)]
        let result = try plan(local, server)
        #expect(result.recordsToUpload.map(\.recordName) == ["b2", "b3"])
        #expect(result.recordsToUpload.map { $0[.order] } == [.number(4), .number(5)])
    }

    @Test func firstLaunchSpacesJoinAndIdenticalRecordNamesTakeServerValues() throws {
        let local = [record(.persona, "default", ["name": .text("Old name")]), space("local", "Personal"),
                     record(.setting, "ARCHAppearance", ["value": .text("dark")])]
        let server = [record(.persona, "default", ["name": .text("Renamed")]), space("remote", "Personal"),
                      record(.setting, "ARCHAppearance", ["value": .text("light")])]
        let result = try plan(local, server)
        #expect(result.recordsToUpload.isEmpty)
        #expect(result.replacements.map(\.localName) == ["local"])
        #expect(result.replacements.map(\.serverName) == ["remote"])
        #expect(result.recordsToApply == Dictionary(uniqueKeysWithValues: server.map { ($0.recordName, $0) }))
    }

    @Test func sameNamedPersonasAndTheirMatchingBookmarksRemainSeparate() throws {
        let local = [record(.persona, "a", ["name": .text("Work")]), space("la", "Research", persona: "a"),
                     record(.favorite, "lf", ["persona": .reference("a"), "url": .text("https://example.test")])]
        let server = [record(.persona, "b", ["name": .text("Work")]), space("rb", "Research", persona: "b"),
                      record(.favorite, "rf", ["persona": .reference("b"), "url": .text("https://example.test")])]
        let result = try plan(local, server)
        #expect(result.recordsToUpload == local)
        #expect(result.replacements.isEmpty)
    }

    @Test func nestedFoldersMatchInTheirMappedParentAndLocalContentsFollowTheMove() throws {
        let local = [tab("new", space: "ls", folder: "lc", url: "https://sample.test/new"),
                     tab("lt", space: "ls", folder: "lc", url: "http://www.sample.test/path/#one"),
                     folder("lc", "Articles", space: "ls", parent: "lf"), folder("lf", "Reading", space: "ls"),
                     folder("extra", "Local", space: "ls", parent: "lc"), space("ls", "Research")]
        let commonParent = folder("rc", "Articles", space: "rs", parent: "rf")
        let remote = [tab("wrong", space: "rs", folder: "other", url: "https://sample.test/path"),
                      tab("rt", space: "rs", folder: "rc", url: "https://sample.test/path#two"),
                      commonParent, folder("rf", "Reading", space: "rs"), space("rs", "Research")]
        let result = try plan(local, remote)
        #expect(result.replacements.map(\.serverName) == ["rs", "rf", "rc", "rt"])
        #expect(result.replacements.map(\.localName) == ["ls", "lf", "lc", "lt"])
        #expect(result.recordsToUpload == [tab("new", space: "rs", folder: "rc", url: "https://sample.test/new"),
                                          folder("extra", "Local", space: "rs", parent: "rc")])
        #expect(result.recordsToApply["rc"] == commonParent)
        let reversed = try plan(local.reversed(), remote.reversed())
        #expect(reversed.replacements == result.replacements)
        #expect(reversed.recordsToApply == result.recordsToApply)
    }

    @Test func sameIDReservesItsMatchBeforeDuplicateNamesAndFillsAMissingValue() throws {
        var exact = space("reserved", "Desk")
        exact[.homeURL] = .text("https://local.test/")
        let a = space("a", "Desk"), b = space("b", "Desk"), new = space("c", "Desk")
        let server = [space("reserved", "Desk"), space("server-b", "Desk"), space("server-a", "Desk")]
        let result = try plan([new, b, a, exact], server)
        #expect(result.replacements.map(\.localName) == ["a", "b"])
        #expect(result.replacements.map(\.serverName) == ["server-a", "server-b"])
        #expect(result.recordsToUpload == [new, exact])
        #expect(result.recordsToApply["reserved"] == exact)
    }

    @Test func favoritesMatchExactAddressesAndTabsKeepDifferentQueriesAndMissingSavedPages() throws {
        let f = record(.favorite, "lf", ["persona": .reference("default"), "url": .text("https://sample.test/#a")])
        var alternate = f
        alternate.recordName = "other"
        alternate[.url] = .text("https://sample.test/#b")
        var remoteFavorite = f
        remoteFavorite.recordName = "rf"
        let locals = [f, alternate, tab("local-query", space: "s", url: "https://sample.test/?a=1"),
                      tab("no-address", space: "s"), tab("relative", space: "s", url: "page")]
        let server = [remoteFavorite, tab("query", space: "s", url: "https://sample.test/?a=2"),
                      tab("empty", space: "s"), tab("remote-relative", space: "s", url: "page")]
        let result = try plan(locals, server)
        #expect(result.replacements.map(\.serverName) == ["rf"])
        #expect(result.recordsToUpload == Array(locals.dropFirst()))
    }

    @Test func anImportedOrdinaryFolderDoesNotReplaceASameNamedLiveFolder() throws {
        let ordinary = folder("imports", "Reading", space: "s")
        var live = folder("live", "Reading", space: "s")
        live.fields["live"] = .text("public feed configuration")
        let result = try plan([ordinary], [live])
        #expect(result.replacements.isEmpty)
        #expect(result.recordsToUpload == [ordinary])
        #expect(result.recordsToApply["live"] == live)
    }

    @Test func invalidIdentitiesFailBeforeProducingAnyPlan() {
        let s = space("collision", "Personal")
        #expect(throws: FirstSyncMerge.InvalidRecords.duplicateName("collision")) { try plan([s, s], []) }
        #expect(throws: FirstSyncMerge.InvalidRecords.duplicateName("collision")) { try plan([], [s, s]) }
        #expect(throws: FirstSyncMerge.InvalidRecords.conflictingTypes("collision")) {
            try plan([s], [record(.persona, "collision", [:])])
        }
    }
}
