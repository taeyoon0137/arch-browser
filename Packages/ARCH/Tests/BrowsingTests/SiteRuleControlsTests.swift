// The rules editor, menus, and palette use the same places and host-only edits.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct SiteRuleControlsTests {
    private func withSession(_ check: (BrowserSession) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSiteRuleControls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        try check(session)
    }

    @Test func placesUseSpaceAloneThenPersonaAndSpace() throws {
        try withSession { session in
            let first = try #require(session.spaces.first)
            #expect(session.siteRulePlace(first) == first.name)
            #expect(session.siteRuleSections.first?.title == nil)
            let work = session.addPersona(named: "Work")
            let mail = session.makeSpace(in: work.id, named: "Mail")
            #expect(session.siteRulePlace(mail) == "Work / Mail")
            #expect(session.siteRuleSections.first { $0.personaID == work.id }?.title == "Work")
        }
    }

    @Test func paletteOffersEachDestinationOnlyForWebPages() throws {
        try withSession { session in
            let first = try #require(session.spaces.first)
            _ = session.makeSpace(in: first.resolvedPersonaID, named: "Later")
            let tab = session.openTab(url: URL(string: "https://example.com/page")!, in: first.id, select: false)
            let commands = session.siteRuleCommands(matching: "always open this site in", forTab: tab)
            #expect(commands.map(\.id) == session.siteRuleDestinations.map(\.id))
            #expect(session.siteRuleCommands(matching: "unrelated", forTab: tab).isEmpty)
            let local = session.openTab(url: URL(fileURLWithPath: "/tmp/example.html"), in: first.id, select: false)
            #expect(session.siteRuleCommands(matching: "always", forTab: local).isEmpty)
        }
    }

    @Test func choosingDestinationEditsTheHostRuleWithoutDuplicatingIt() throws {
        try withSession { session in
            let first = try #require(session.spaces.first)
            let later = session.makeSpace(in: first.resolvedPersonaID, named: "Later")
            let url = URL(string: "https://example.com/work?q=private")!
            try session.setSiteRule(for: url, destination: first)
            let id = try #require(session.siteRules.rules.first?.id)
            try session.setSiteRule(for: url, destination: later)
            #expect(session.siteRules.rules.count == 1)
            let rule = try #require(session.siteRules.rules.first)
            #expect(rule.id == id && rule.host == "example.com" && rule.pathPrefix.isEmpty && rule.spaceID == later.id)
        }
    }

    @Test func anywhereRemovesTheRuleTheMenuShows() throws {
        try withSession { session in
            let first = try #require(session.spaces.first)
            try session.setSiteRule(for: URL(string: "https://example.com")!, destination: first)
            let child = URL(string: "https://mail.example.com/inbox")!
            #expect(session.siteRule(for: child) != nil)
            try session.setSiteRule(for: child, destination: nil)
            #expect(session.siteRule(for: child) == nil)
        }
    }
    @Test func quickControlsExplainThePathRuleThatKeepsItsDestination() throws {
        try withSession { session in
            let first = try #require(session.spaces.first)
            let later = session.makeSpace(in: first.resolvedPersonaID, named: "Later")
            let page = URL(string: "https://example.com/work/inbox")!
            let pathRule = SiteRule(host: "example.com", pathPrefix: "/work", spaceID: first.id, personaID: first.resolvedPersonaID)
            try session.siteRules.save(pathRule)
            try session.setSiteRule(for: page, destination: later)

            #expect(session.siteRule(for: page)?.id == pathRule.id)
            #expect(session.quickRuleNote(for: page)?.contains("example.com/work") == true)
            #expect(session.quickRuleNote(for: URL(string: "https://example.com/personal")!) == nil)
            // An exact subdomain rule beats its parent's path rule, so it needs no path warning.
            #expect(session.quickRuleNote(for: URL(string: "https://mail.example.com/work")!) == nil)
        }
    }

    @Test func anywhereExplainsTheRemainingMatchWithoutRemovingIt() throws {
        try withSession { session in
            let first = try #require(session.spaces.first)
            let inherited = SiteRule(host: "example.com", spaceID: first.id, personaID: first.resolvedPersonaID)
            let specific = SiteRule(host: "mail.example.com", pathPrefix: "/work", spaceID: first.id, personaID: first.resolvedPersonaID)
            try session.siteRules.save(inherited)
            try session.siteRules.save(specific)
            let page = URL(string: "https://mail.example.com/work")!

            let note = try #require(session.quickRuleNote(for: page, removing: true))
            #expect(note.contains("mail.example.com/work") && note.contains("example.com"))
            try session.setSiteRule(for: page, destination: nil)
            #expect(session.siteRule(for: page)?.id == inherited.id)
            #expect(session.siteRules.rules == [inherited])
            #expect(session.quickRuleNote(for: page, removing: true) == nil)
        }
    }

}
