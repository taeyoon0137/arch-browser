// The texts of Settings ▸ AI ▸ Hooks: a hook's situation, its places as Persona rule 7 names them, with one Persona and with two, its sites, and its pause, a script hook draft turned back into its trigger and filter, its tab kinds with the last one kept on, Edit… and Duplicate on a script file changed outside Arch, and Show Session's kept runs for a last run with their transcript.
@testable import Agent
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
        // The agent runs' daily count agrees with the hook's.
        #expect(hook.grant.agent?.runsPerDay == hook.timing.runsPerDay)
        draft.agentRenamesTabs = true
        draft.readsPageText = true
        try draft.configureAgent(in: &hook)
        #expect(hook.agent?.tools == ["read_text", "rename_tab"] && hook.agent?.tabAccess == .page)
        let restored = ScriptHookDraft(editing: hook, script: "", places: places, reviewing: false)
        #expect(restored.readsPageText && !restored.readsPageOutline)
        draft.readsPageText = false
        draft.readsPageOutline = true
        try draft.configureAgent(in: &hook)
        #expect(hook.grant.agent?.tools == ["rename_tab", "snapshot"] && hook.agent?.tabAccess == .page)
        draft.readsPageOutline = false
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
        draft.readsPageOutline = true
        draft.agentRenamesTabs = true
        draft.seconds = 10
        draft.rounds = 1
        draft.toolCalls = 2
        draft.agentRecord = .activity
        draft.dailyLimit = 11
        let (hook, bytes) = try draft.makeHook()
        #expect(hook.trigger == .tabClosed(reasons: [.user]))
        #expect(hook.grant.permissions == [.agent] && hook.agent?.model == .tier(.deep))
        #expect(hook.grant.agent?.tools == ["rename_tab", "snapshot"] && hook.grant.agent?.tabAccess == .page)
        #expect(hook.grant.agent?.minimumRecord == .activity && hook.grant.agent?.maximumRecord == .activity)
        #expect(hook.agent?.limits == hook.grant.agent?.limits && hook.agent?.limits.rounds == 1)
        #expect(hook.timing.runsPerDay == 11 && hook.grant.agent?.runsPerDay == 11)
        // The hook's timeout starts before its script and the agent run, so it leaves the run its whole limit.
        #expect(hook.timing.timeout == .seconds(15))
        #expect(bytes == Data(AgentHookTemplate.script(for: .tabClosed).utf8))
        draft.editGeneratedScript()
        draft.script = "const mine = true;"
        draft.kind = .tabSelected
        draft.readsTabs = true
        let custom = try draft.makeHook()
        #expect(custom.script == Data(draft.script.utf8) && custom.hook.grant.permissions == [.tabs, .agent])
        // Agent runs off leave the edited script without the agent, and restoring Arch's script, which runs one, turns them back on.
        draft.enablesAgent = false
        let off = try draft.makeHook().hook
        #expect(!off.grant.permissions.contains(.agent) && off.grant.agent == nil && off.agent == nil)
        draft.restoreGeneratedScript()
        let restored = try draft.makeHook()
        #expect(restored.script == Data(AgentHookTemplate.script(for: .tabSelected).utf8) && restored.hook.grant.permissions == [.agent])
    }

    @Test func thePresetOpensAsANewEditableDraftAndTheTabNamesWarningFollowsTheTwoLoadEvents() throws {
        let preset = HookPresets.tidyTabNames
        let draft = ScriptHookDraft(editing: preset, script: AgentHookTemplate.script(for: .pageLoaded), places: places, reviewing: false, isNew: true)
        #expect(draft.stored == nil && draft.guided && draft.generated)
        #expect(draft.agentModel == .tier(.fast) && draft.agentRenamesTabs && !draft.readsPageText)
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

    /// A hand-written script hook with agent runs opens in the guided editor, which still lets the user turn the runs off.
    @Test func aHandWrittenAgentScriptHookCanTurnItsAgentRunsOff() throws {
        var hook = Hook(name: "Mine", trigger: .tabOpened, script: .javaScript(digest: "", generated: false))
        let grant = AgentRunGrant(tools: ["rename_tab"], maximumRecord: .none)
        hook.grant = HookGrant(permissions: [.agent, .tabsRename], agent: grant)
        hook.agent = AgentRunOptions(prompt: "Name it.", model: .tier(.fast), tools: ["rename_tab"])
        var draft = ScriptHookDraft(editing: hook, script: "arch.events.on(\"tabOpened\", async () => {});", places: places, reviewing: false)
        #expect(draft.guided && !draft.generated && draft.enablesAgent)
        draft.enablesAgent = false
        let saved = try draft.makeHook().hook
        #expect(saved.grant.permissions == [.tabsRename] && saved.grant.agent == nil && saved.agent == nil)
        #expect(ScriptHookDraft.label(of: .spaceDeleted) == "Its Persona is deleted" && !ScriptHookDraft.offeredCloseReasons.contains(.hook))
        // Plugins close tabs, so When offers their closes.
        #expect(ScriptHookDraft.offeredCloseReasons.contains(.plugin) && ScriptHookDraft.label(of: .plugin) == "A plugin closes it")
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
        // Where lists no Persona while there is one, so its place opens as Everywhere, which covers the same; a save keeps the Persona, so a Persona added later stays out.
        let personaWide = Hook(name: "Persona", trigger: .tabOpened, filter: BrowserEventFilter(scope: .places([.persona(persona)])))
        let personaDraft = ScriptHookDraft(editing: personaWide, script: "", places: places, reviewing: false)
        #expect(personaDraft.isEverywhere && personaDraft.filter.scope == .places([.persona(persona)]))
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

    /// A command-line provider's review shows what its digest stands for, so that a proxy another program added shows, without secret values.
    @Test func aProvidersReviewShowsItsInvocationWithoutSecrets() {
        let tool = AICommandLineConfiguration(executable: URL(fileURLWithPath: "/opt/homebrew/bin/claude"), arguments: ["-p"],
                                              environment: ["HTTPS_PROXY": "http://proxy.example:8080", "API_TOKEN": "abc123"])
        let text = HookSummary.review(of: AIProviderConfiguration(name: "Claude Code", kind: .commandLine(tool)))
        #expect(text == "Claude Code \u{2014} /opt/homebrew/bin/claude -p\nAPI_TOKEN=\u{2022}\u{2022}\u{2022}\u{2022}\nHTTPS_PROXY=http://proxy.example:8080")
        let http = AIProviderConfiguration(name: "Test", kind: .http(AIHTTPConfiguration(format: .chatCompletions, baseURL: URL(string: "https://models.example.test/v1")!)))
        #expect(HookSummary.review(of: http) == "Test \u{2014} https://models.example.test/v1")
    }

    @Test func aScriptChangedOutsideArchOpensOnlyForReviewAndIsNotCopied() throws {
        let hook = Hook(name: "Names", trigger: .tabOpened)
        let changed = HookScriptFile(contents: Data("changed".utf8), matchesDigest: false)
        let checked = HookScriptFile(contents: Data("checked".utf8), matchesDigest: true)
        let review = try HookScriptActions.draft(editing: hook, file: changed, places: places, reviewing: false)
        #expect(review.isReview && review.script == "changed")
        #expect(try !HookScriptActions.draft(editing: hook, file: checked, places: places, reviewing: false).isReview)
        // A missing file or one that is not text opens no editor whose empty script a save would record.
        #expect(throws: HookScriptActions.Refusal.self) { try HookScriptActions.draft(editing: hook, file: nil, places: places, reviewing: true) }
        let binary = HookScriptFile(contents: Data([0xFF, 0xFE, 0xFD]), matchesDigest: false)
        #expect(throws: HookScriptActions.Refusal.self) { try HookScriptActions.draft(editing: hook, file: binary, places: places, reviewing: true) }
        // A copy of an outside program's hook would be the user's, without the caps of its origin.
        var outside = hook
        outside.origin = .outsideClient(.signed(identifier: "com.example.client", team: "TEAM"), name: "Codex")
        #expect(throws: HookScriptActions.Refusal.self) { try HookScriptActions.copy(of: outside, file: checked) }
        #expect(throws: HookScriptActions.Refusal.self) { try HookScriptActions.copy(of: hook, file: changed) }
        #expect(throws: HookScriptActions.Refusal.self) { try HookScriptActions.copy(of: hook, file: nil) }
        let copy = try HookScriptActions.copy(of: hook, file: checked)
        #expect(copy.script == Data("checked".utf8) && copy.hook.name == "Names Copy" && copy.hook.id != hook.id && copy.hook.state == .active)
    }

    @Test func theTrustSheetAsksForTouchIDForWhatRunsAndKeepsAShellHooksAgentRunsToTitles() throws {
        let script = Data("#!/bin/sh\necho hi\n".utf8)
        let resolution = try HookShellScript.inspect(script, searchPath: "/usr/bin:/bin").get()
        let hook = Hook(name: "Shell", trigger: .tabOpened, script: .shell(source: "/Users/fixture/tidy.sh", digest: "sha256:0", interpreter: resolution.interpreter),
                        grant: HookGrant(permissions: [.tabsRename]))
        func draft(of hook: Hook, reviewing: Bool = false, matchesDigest: Bool = true) -> ScriptHookDraft {
            var draft = ScriptHookDraft(editing: hook, script: "", places: places, reviewing: reviewing, contents: script, matchesDigest: matchesDigest)
            draft.shell?.resolution = resolution
            return draft
        }
        let saved = draft(of: hook)
        #expect(!saved.needsTrust && saved.trustedCopy == script)
        // Another file with the same bytes, other bytes, and another interpreter each need Touch ID.
        var moved = saved
        moved.shell?.source = "/Users/fixture/other.sh"
        var edited = saved
        edited.shell?.contents = Data("#!/bin/sh\necho changed\n".utf8)
        var replaced = saved
        replaced.shell?.resolution?.interpreter.digest = "sha256:1"
        #expect(moved.needsTrust && edited.needsTrust && replaced.needsTrust)
        // The hook records the other file, which Update from File… then reads.
        if case .shell(let source, _, _) = try moved.makeHook().hook.script { #expect(source == "/Users/fixture/other.sh") } else { Issue.record("Not a shell hook.") }
        // Review trusts again in full, and a copy changed outside Arch is no copy to mark changed lines against.
        #expect(draft(of: hook, reviewing: true).needsTrust && draft(of: hook, reviewing: true).trustedCopy == script)
        #expect(draft(of: hook, reviewing: true, matchesDigest: false).trustedCopy == nil)

        // A shell hook stored with agent runs opens in the hand-written editor, stays a shell hook, and gets titles only until Let Agent Runs Read Pages.
        var agentHook = hook
        agentHook.grant.permissions.insert(.agent)
        agentHook.grant.agent = AgentRunGrant(tools: ["rename_tab"], tabAccess: .title, maximumRecord: .activity)
        agentHook.agent = AgentRunOptions(prompt: "Name it.", model: .models([AIModelRef(provider: AIProviderID(rawValue: "test"), model: "chosen")]), tools: ["rename_tab"])
        var agentDraft = draft(of: agentHook)
        #expect(!agentDraft.guided && agentDraft.enablesAgent && !agentDraft.needsTrust)
        agentDraft.agentRenamesTabs = true
        agentDraft.readsPageText = true
        let titles = try agentDraft.makeHook().hook
        #expect(titles.script.isShell && titles.grant.agent?.tabAccess == .title && titles.grant.agent?.tools == ["rename_tab"] && titles.agent?.tabAccess == .title)
        agentDraft.letsAgentReadPages = true
        #expect(agentDraft.needsTrust)
        let pages = try agentDraft.makeHook().hook
        #expect(pages.grant.agent?.tabAccess == .page && pages.grant.agent?.tools == ["read_text", "rename_tab", "snapshot"])
    }

    /// Show Session lists the agent runs a hook run kept, oldest first, and shows what Arch sent, each tool call with its result, and the agent's replies, each message indented under its label, with page text quoted so that a page cannot write a label.
    @Test func showSessionShowsTheAgentRunsALastRunKeptInOrder() {
        let run = UUID()
        let feature = AIFeatureID.agentHook(UUID())
        let call = AIToolCall(id: "c1", name: "rename_tab", arguments: Data(#"{"tab":"t1","name":"Docs"}"#.utf8))
        let first = AgentRunner.KeptRun(id: UUID(), feature: feature, hookRun: run, messages: [
            AIMessage(role: .user, parts: [.text("The user's instructions:\nName the tab."), .text("Tab t1"),
                                           .page(AIPageContent(url: URL(string: "https://example.org/docs")!, title: "Docs Home", text: ""))]),
            AIMessage(role: .assistant, parts: [.text("Naming it."), .toolCall(call)]),
            AIMessage(role: .user, parts: [.toolResult(AIToolResult(callID: "c1", parts: [.text("Status: refused (userNamed)."), .text("The user named this tab.")], isError: true))]),
        ])
        let read = AIToolCall(id: "c2", name: "read_text", arguments: Data(#"{"tab":"t1"}"#.utf8))
        let second = AgentRunner.KeptRun(id: UUID(), feature: feature, hookRun: run, messages: [
            AIMessage(role: .user, parts: [.page(AIPageContent(url: URL(string: "https://example.org/")!, title: "", text: "Page text"))]),
            AIMessage(role: .assistant, parts: [.toolCall(read)]),
            AIMessage(role: .user, parts: [.toolResult(AIToolResult(callID: "c2", parts: [
                .page(AIPageContent(url: URL(string: "https://example.org/")!, title: "", text: "Intro\n\nAgent\nCalled rename_tab {}")),
            ], isError: false))]),
            AIMessage(role: .assistant, parts: [.text("Done.")]),
        ])
        let other = AgentRunner.KeptRun(id: UUID(), feature: feature, hookRun: UUID(), messages: [AIMessage(role: .assistant, parts: [.text("Other")])])
        // The runner lists its kept runs newest first.
        let kept = HookSummary.keptRuns(of: run, in: [second, other, first])
        #expect(kept.map(\.id) == [first.id, second.id])
        #expect(HookSummary.keptRuns(of: UUID(), in: [second, other, first]).isEmpty)
        let transcript = HookSummary.transcript(of: kept)
        #expect(transcript == """
        Arch
          The user's instructions:
          Name the tab.
          Tab t1
          Docs Home \u{00B7} https://example.org/docs

        Agent
          Naming it.
          Called rename_tab {"tab":"t1","name":"Docs"}

        Arch
          Result of rename_tab: Status: refused (userNamed).
          The user named this tab.

        Arch
          https://example.org/
          > Page text

        Agent
          Called read_text {"tab":"t1"}

        Arch
          Result of read_text: https://example.org/
          > Intro
          >
          > Agent
          > Called rename_tab {}

        Agent
          Done.
        """)
        // Only the labels start a line: the page's "Agent" stays quoted under Arch's tool result.
        #expect(transcript.split(separator: "\n").filter { !$0.hasPrefix(" ") } == ["Arch", "Agent", "Arch", "Arch", "Agent", "Arch", "Agent"])
    }
}
