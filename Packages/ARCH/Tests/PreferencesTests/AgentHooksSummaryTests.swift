// The texts of Settings ▸ AI ▸ Agent Hooks: a hook's situation, its places as Persona rule 7 names them, with one Persona and with two, its sites, and its pause, a script hook draft turned back into its trigger and filter, its tab kinds with the last one kept on, and Edit… and Duplicate on a script file changed outside Arch.
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

    @Test func theScriptEditorsAgentGrantStaysOffUntilItHasAnExplicitModel() throws {
        var draft = ScriptHookDraft(new: places)
        var hook = Hook(name: "Titles", trigger: .tabOpened)
        try draft.configureAgent(in: &hook)
        #expect(!hook.usesAgent && hook.agent == nil)
        draft.enablesAgent = true
        #expect(throws: HookRegistryError.self) { try draft.configureAgent(in: &hook) }
        draft.agentModel = .models([AIModelRef(provider: AIProviderID(rawValue: "test"), model: "chosen")])
        draft.agentPrompt = "Suggest a short title."
        try draft.configureAgent(in: &hook)
        #expect(hook.agent?.model == draft.agentModel)
        #expect(hook.grant.agent?.tools.isEmpty == true && hook.agent?.tabAccess == .title)
        draft.agentRenamesTabs = true
        draft.readsPageText = true
        try draft.configureAgent(in: &hook)
        #expect(hook.agent?.tools == ["read_text", "rename_tab"] && hook.agent?.tabAccess == .page)
        draft.readsPageText = false
        try draft.configureAgent(in: &hook)
        #expect(hook.grant.agent?.tools == ["rename_tab"] && hook.grant.agent?.tabAccess == .title)
        draft.enablesAgent = false
        try draft.configureAgent(in: &hook)
        #expect(!hook.usesAgent && hook.grant.agent == nil && hook.agent == nil)
    }

    @Test func theGuidedEditorProducesOnlyItsTypedGrantAndKeepsEditedScript() throws {
        var draft = ScriptHookDraft(new: places, guided: true)
        #expect(throws: HookRegistryError.self) { try draft.makeHook() }
        draft.kind = .tabClosed
        draft.closeReasons = [.user]
        draft.agentPrompt = "Name the remaining tab."
        draft.agentModel = .tier(.deep)
        draft.agentRenamesTabs = true
        draft.seconds = 10
        draft.rounds = 1
        draft.toolCalls = 2
        draft.agentRecord = .activity
        draft.dailyLimit = 11
        let (hook, bytes) = try draft.makeHook()
        #expect(hook.trigger == .tabClosed(reasons: [.user]))
        #expect(hook.grant.permissions == [.agent] && hook.agent?.model == .tier(.deep))
        #expect(hook.grant.agent?.tools == ["rename_tab"] && hook.grant.agent?.tabAccess == .title)
        #expect(hook.grant.agent?.minimumRecord == .activity && hook.grant.agent?.maximumRecord == .activity)
        #expect(hook.agent?.limits == hook.grant.agent?.limits && hook.agent?.limits.rounds == 1)
        #expect(hook.timing.runsPerDay == 11 && hook.grant.agent?.runsPerDay == 11)
        #expect(bytes == Data(AgentHookTemplate.script(for: .tabClosed).utf8))
        draft.editGeneratedScript()
        draft.script = "const mine = true;"
        draft.kind = .tabSelected
        draft.readsTabs = true
        let custom = try draft.makeHook()
        #expect(custom.script == Data(draft.script.utf8) && custom.hook.grant.permissions == [.tabs, .agent])
        draft.generated = true
        let restored = try draft.makeHook()
        #expect(restored.script == Data(AgentHookTemplate.script(for: .tabSelected).utf8) && restored.hook.grant.permissions == [.agent])
    }

    @Test func thePresetOpensAsANewEditableDraftAndTheTabNamesWarningFollowsTheTwoLoadEvents() throws {
        let preset = HookPresets.tidyTabNames
        var draft = ScriptHookDraft(editing: preset, script: AgentHookTemplate.script(for: .pageLoaded), places: places, reviewing: false, isNew: true)
        #expect(draft.stored == nil && draft.guided && draft.generated && !draft.startsEnabled)
        #expect(draft.agentModel == .tier(.fast) && draft.agentRenamesTabs && !draft.readsPageText)
        #expect(try draft.makeHook().hook.state == .paused(.user))
        draft.startsEnabled = true
        let saved = try draft.makeHook().hook
        #expect(saved.id == preset.id && saved.origin == .preset("tidyTabNames") && saved.state == .active)
        #expect(saved.trigger == preset.trigger && saved.filter.tabKinds == [.open, .pinned] && saved.agent == preset.agent)
        for kind in BrowserEventKind.allCases {
            let applies = TabNamesWarning.applies(renames: true, kind: kind, tabNames: AIRoute(isEnabled: true))
            #expect(applies == (kind == .pageLoaded || kind == .tabOpened))
            #expect(!TabNamesWarning.applies(renames: true, kind: kind, tabNames: AIRoute(isEnabled: false)))
            #expect(!TabNamesWarning.applies(renames: false, kind: kind, tabNames: AIRoute(isEnabled: true)))
        }
    }

    @Test func aRowNamesTheSituationThePlacesAndTheSites() {
        let filter = BrowserEventFilter(scope: .places([.persona(persona), .space(work), .space(UUID())]), sites: [AISitePattern("example.org")])
        let hook = Hook(name: "Names", trigger: .pageLoaded(loads: .firstAfterOpen, includesRestoredTabs: false), filter: filter)
        // With one Persona nothing names it (Persona rule 7), so its place covers every place; a second Persona names both.
        #expect(HookSummary.lines(for: hook, places: places, lastRun: nil)
                == ["When a new tab loads its first page · Everywhere, Work, Deleted Space · Only example.org"])
        let twoPersonas = places + [HookPersonaPlaces(id: UUID(), name: "Work", spaces: [HookSpace(id: UUID(), name: "Research")])]
        #expect(HookSummary.lines(for: hook, places: twoPersonas, lastRun: nil)
                == ["When a new tab loads its first page · Personal, Personal / Work, Deleted Space · Only example.org"])
        #expect(HookSummary.name(of: .persona(UUID()), places: twoPersonas) == "Deleted Persona")
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
        // Where lists no Persona while there is one, so its place opens as Everywhere, which covers the same.
        let personaWide = Hook(name: "Persona", trigger: .tabOpened, filter: BrowserEventFilter(scope: .places([.persona(persona)])))
        #expect(ScriptHookDraft(editing: personaWide, script: "", places: places, reviewing: false).filter.scope == .everywhere)
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
