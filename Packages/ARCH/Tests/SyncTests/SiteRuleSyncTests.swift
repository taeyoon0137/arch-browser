import Browsing
import CloudKit
import Foundation
import Sync
import Testing

@Suite struct SiteRuleSyncTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800)

    private func records(persona: Persona, space: Space, rules: [SiteRule]) throws -> [SyncRecord] {
        try SidebarRecords.records(from: SidebarSyncState(personas: [persona], spaces: [space], folders: [], favorites: [], pinnedTabs: [], siteRules: rules), foundAt: now)
    }

    @Test func rulesRoundTripWithEncryptedSitesAndPlainDestinations() throws {
        let persona = Persona(id: Persona.defaultID, name: "Home"), space = Space(name: "Mail")
        let rule = SiteRule(host: "mail.example.test", pathPrefix: "/work", spaceID: space.id, personaID: persona.id, window: .newWindow, modifiedAt: now)
        let rows = try records(persona: persona, space: space, rules: [rule])
        let record = try #require(rows.first { $0.recordType == .siteRule })
        #expect(record.schemaVersion == 3 && record[.order] == nil)
        #expect(SyncOrderKeys.SiblingList(of: record) == nil)
        let cloud = SyncCloudKitRecords.ckRecord(from: record)
        for field in ["host", "pathPrefix", "window", "fieldModifiedAt"] {
            #expect(cloud.encryptedValues[field] != nil && cloud[field] == nil)
        }
        #expect((cloud["persona"] as? CKRecord.Reference)?.recordID.recordName == "default")
        #expect((cloud["space"] as? CKRecord.Reference)?.recordID.recordName == space.id.uuidString)
        #expect(cloud.encryptedValues["persona"] == nil && cloud.encryptedValues["space"] == nil)
        let copy = try #require(SyncCloudKitRecords.syncRecord(from: cloud))
        let plan = try IncomingSidebarRecords.plan(records: rows.map { $0.recordName == copy.recordName ? copy : $0 }, deleted: [:], foundAt: now, defaultEngine: .webKit)
        #expect(plan.sidebar.siteRules == [rule])
    }

    @Test func siteAndDestinationMergeIndependentlyButTheirFieldsStayTogether() {
        let initial = SyncRecord(recordType: .siteRule, recordName: UUID().uuidString, fields: [
            "host": .text("example.test"), "pathPrefix": .text("/old"), "persona": .reference("default"),
            "space": .reference(UUID().uuidString), "window": .text("space")], modifiedAt: now)
        var local = initial, server = initial
        local[.host] = .text("local.example.test")
        local.fieldModifiedAt["host"] = now.addingTimeInterval(10)
        server[.pathPrefix] = .text("/remote")
        server.fieldModifiedAt["pathPrefix"] = now.addingTimeInterval(20)
        local[.persona] = .reference(UUID().uuidString)
        local[.space] = .reference(UUID().uuidString)
        local.fieldModifiedAt["space"] = now.addingTimeInterval(30)
        server[.window] = .text("newWindow")
        server.fieldModifiedAt["window"] = now.addingTimeInterval(25)
        let merged = SyncMerge.merge(local: local, server: server, base: .mirror(initial))
        #expect(merged.record[.host] == initial[.host] && merged.record[.pathPrefix] == server[.pathPrefix])
        #expect(merged.record[.persona] == local[.persona] && merged.record[.space] == local[.space])
        #expect(merged.record[.window] == initial[.window] && merged.needsSend)
    }

    @Test func firstSyncJoinsOnlyTheSameSiteInTheSamePersonaAndRemapsSpaces() throws {
        let persona = Persona(id: Persona.defaultID, name: "Home"), localSpace = Space(name: "Mail"), remoteSpace = Space(name: "Mail")
        let local = SiteRule(host: "example.test", pathPrefix: "/work", spaceID: localSpace.id, personaID: persona.id)
        let remote = SiteRule(host: local.host, pathPrefix: local.pathPrefix, spaceID: remoteSpace.id, personaID: persona.id, window: .newWindow)
        let otherPath = SiteRule(host: local.host, pathPrefix: "/personal", spaceID: localSpace.id, personaID: persona.id)
        let otherPersona = SiteRule(host: local.host, pathPrefix: local.pathPrefix, spaceID: localSpace.id, personaID: UUID())
        let plan = try FirstSyncMerge.plan(local: records(persona: persona, space: localSpace, rules: [local, otherPath, otherPersona]),
            server: records(persona: persona, space: remoteSpace, rules: [remote]), samePage: { $0 == $1 })
        #expect(plan.replacements.contains { $0.type == .siteRule && $0.localName == local.id.uuidString && $0.serverName == remote.id.uuidString })
        #expect(plan.recordsToUpload.filter { $0.recordType == .siteRule }.count == 2)
        #expect(plan.recordsToUpload.first { $0.recordName == otherPath.id.uuidString }?[.space] == .reference(remoteSpace.id.uuidString))
        #expect(plan.recordsToApply[remote.id.uuidString]?[.window] == .text("newWindow"))
    }

    @Test func unknownDestinationsWaitAndApplyWhenTheirRecordsArrive() throws {
        let persona = Persona(name: "Work"), space = Space(name: "Mail", personaID: persona.id)
        let rule = SiteRule(host: "example.test", spaceID: space.id, personaID: persona.id)
        let rows = try records(persona: persona, space: space, rules: [rule])
        let onlyRule = rows.filter { $0.recordType == .siteRule }
        #expect(IncomingSidebarRecords.heldOut(server: onlyRule, local: []) == [rule.id.uuidString])
        let held = try IncomingSidebarRecords.plan(records: onlyRule, deleted: [:], foundAt: now, defaultEngine: .webKit)
        #expect(held.sidebar.siteRules.isEmpty && held.recordsToDelete.isEmpty)
        let missingSpace = rows.filter { $0.recordType != .space }
        #expect(IncomingSidebarRecords.heldOut(server: missingSpace, local: []) == [rule.id.uuidString])
        let arrived = try IncomingSidebarRecords.plan(records: rows, deleted: [:], foundAt: now, defaultEngine: .webKit)
        #expect(arrived.sidebar.siteRules.map(\.id) == [rule.id] && arrived.recordsToDelete.isEmpty)
    }

    @Test func deletedSpaceKeepsItsReferenceAndDeletedPersonaRemovesTheRule() throws {
        let persona = Persona(name: "Work"), space = Space(name: "Mail", personaID: persona.id)
        let rule = SiteRule(host: "example.test", spaceID: space.id, personaID: persona.id)
        let rows = try records(persona: persona, space: space, rules: [rule])
        let spaceDeleted = try IncomingSidebarRecords.plan(records: rows, deleted: [space.id.uuidString: .space], foundAt: now, defaultEngine: .webKit)
        #expect(spaceDeleted.sidebar.siteRules.first?.spaceID == space.id)
        #expect(spaceDeleted.sidebar.spaces.first?.id != space.id && spaceDeleted.recordsToDelete.isEmpty)
        let known = try IncomingSidebarRecords.plan(local: rows.filter { $0.recordType != .space }, fetched: [], mirror: rows.filter { $0.recordType != .space }, deleted: [:], foundAt: now, defaultEngine: .webKit)
        #expect(known.sidebar.siteRules.map(\.id) == [rule.id])
        let personaDeleted = try IncomingSidebarRecords.plan(records: rows, deleted: [persona.id.uuidString: .persona], foundAt: now, defaultEngine: .webKit)
        #expect(personaDeleted.sidebar.siteRules.isEmpty && personaDeleted.deletions.siteRules == [rule.id])
        #expect(personaDeleted.recordsToDelete.contains(rule.id.uuidString))
    }

    @Test func destinationCanChangePersonasAndUnknownWindowValuesWait() throws {
        let first = Persona(name: "Home"), second = Persona(name: "Work")
        let source = Space(name: "Personal", personaID: first.id), target = Space(name: "Mail", personaID: second.id)
        let rule = SiteRule(host: "example.test", spaceID: source.id, personaID: first.id)
        let local = try records(persona: first, space: source, rules: [rule]) + records(persona: second, space: target, rules: [])
        var moved = try #require(local.first { $0.recordType == .siteRule })
        moved[.persona] = .reference(second.id.uuidString)
        moved[.space] = .reference(target.id.uuidString)
        #expect(IncomingSidebarRecords.heldOut(server: [moved], local: local).isEmpty)
        let plan = try IncomingSidebarRecords.plan(local: local, fetched: [moved], mirror: local, deleted: [:], foundAt: now, defaultEngine: .webKit)
        #expect(plan.sidebar.siteRules.first?.personaID == second.id)
        moved[.window] = .text("futureWindow")
        #expect(IncomingSidebarRecords.heldOut(server: [moved], local: local) == [rule.id.uuidString])
    }

    @Test func aDestinationEditedToAnUnknownSpaceWaitsInsteadOfUsingTheLocalFallback() throws {
        let persona = Persona(id: Persona.defaultID, name: "Home"), space = Space(name: "Mail")
        let rule = SiteRule(host: "example.test", spaceID: space.id, personaID: persona.id)
        let rows = try records(persona: persona, space: space, rules: [rule])
        var moved = try #require(rows.first { $0.recordType == .siteRule })
        moved[.space] = .reference(UUID().uuidString)
        #expect(IncomingSidebarRecords.heldOut(server: [moved], local: rows) == [rule.id.uuidString])
        let deleted = try IncomingSidebarRecords.plan(records: rows, deleted: [rule.id.uuidString: .siteRule], foundAt: now, defaultEngine: .webKit)
        #expect(deleted.sidebar.siteRules.isEmpty && deleted.deletions.siteRules == [rule.id])
    }
}
