// The texts of Settings ▸ AI ▸ Agent Hooks: a hook's situation, its places as "Persona" and "Persona / Space", its sites, and its pause, a script hook draft turned back into its trigger and filter, its tab kinds with the last one kept on, and Edit… and Duplicate on a script file changed outside Arch.
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

    @Test func theLastTabKindLeftOnStaysOn() {
        var draft = ScriptHookDraft(new: places)
        #expect(draft.tabKinds.isEmpty && draft.includes(.favorite))
        for kind in [BrowserTabKind.open, .pinned, .favorite] {
            #expect(draft.mayExclude(kind))
            draft.setIncludes(kind, false)
        }
        #expect(draft.tabKinds == [.smallWindow])
        // Turning the last one off would leave an empty set, which reads as every kind.
        #expect(!draft.mayExclude(.smallWindow))
        draft.setIncludes(.smallWindow, false)
        #expect(draft.tabKinds == [.smallWindow] && !draft.includes(.open))
        for kind in [BrowserTabKind.open, .pinned, .favorite] {
            draft.setIncludes(kind, true)
        }
        #expect(draft.tabKinds.isEmpty)
    }

    @Test func aScriptChangedOutsideArchOpensOnlyForReviewAndIsNotCopied() throws {
        let hook = Hook(name: "Names", trigger: .tabOpened)
        let changed = HookScriptFile(contents: Data("changed".utf8), matchesDigest: false)
        let checked = HookScriptFile(contents: Data("checked".utf8), matchesDigest: true)
        let review = HookScriptActions.draft(editing: hook, file: changed, places: places, reviewing: false)
        #expect(review.isReview && review.script == "changed")
        #expect(!HookScriptActions.draft(editing: hook, file: checked, places: places, reviewing: false).isReview)
        #expect(throws: HookScriptActions.Refusal.self) { try HookScriptActions.copy(of: hook, file: changed) }
        #expect(throws: HookScriptActions.Refusal.self) { try HookScriptActions.copy(of: hook, file: nil) }
        let copy = try HookScriptActions.copy(of: hook, file: checked)
        #expect(copy.script == Data("checked".utf8) && copy.hook.name == "Names Copy" && copy.hook.id != hook.id && copy.hook.state == .active)
    }
}
