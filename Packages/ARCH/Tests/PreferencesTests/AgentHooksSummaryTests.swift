// The texts of Settings ▸ AI ▸ Agent Hooks: a hook's situation, its places as "Persona" and "Persona / Space", its sites, and its pause, and a script hook draft turned back into its trigger and filter.
import AI
import Events
import Foundation
import Hooks
import Testing
@testable import Preferences

@MainActor
@Suite struct AgentHooksSummaryTests {
    private let persona = UUID()
    private let work = UUID()
    private var places: [HookPersonaPlaces] {
        [HookPersonaPlaces(id: persona, name: "Personal", spaces: [HookSpace(id: work, name: "Work")])]
    }

    @Test func aRowNamesTheSituationThePlacesAndTheSites() {
        let filter = BrowserEventFilter(scope: .places([.persona(persona), .space(work), .space(UUID())]), sites: [AISitePattern("example.org")])
        let hook = Hook(name: "Names", trigger: .pageLoaded(loads: .firstAfterOpen, includesRestoredTabs: false), filter: filter)
        #expect(HookSummary.lines(for: hook, places: places, lastRun: nil)
                == ["When a new tab loads its first page · Personal, Personal / Work, A deleted space · Only example.org"])
        #expect(HookSummary.scope(of: .everywhere, places: places) == "Everywhere")
        #expect(HookSummary.situation(of: .tabClosed(reasons: [.user])) == "When you close a tab")
        #expect(HookSummary.sentence(for: .scriptChanged) == "Its script changed outside Arch.")
    }

    @Test func aDraftKeepsTheHooksTriggerAndFilter() {
        let filter = BrowserEventFilter(kinds: [.titleChanged], scope: .places([.space(work)]), exceptSites: [AISitePattern("example.org")], engines: [.chromium], tabKinds: [.pinned])
        let hook = Hook(name: "Titles", trigger: .titleChanged(sources: [.suggested]), filter: filter, grant: HookGrant(permissions: [.tabsRename]))
        let draft = ScriptHookDraft(editing: hook, script: "", places: places, reviewing: false)
        #expect(draft.trigger == hook.trigger)
        #expect(draft.filter == filter)
        #expect(draft.renamesTabs && !draft.readsTabs)
        var new = ScriptHookDraft(new: places)
        #expect(new.script == ScriptHookDraft.template(for: .pageLoaded))
        new.siteChoice = .only
        new.siteList = "example.org, not a site"
        #expect(new.sitePatterns().problem == "\u{201C}not a site\u{201D} is not a site.")
    }
}
