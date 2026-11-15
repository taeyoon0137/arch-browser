// The JavaScript hook runner (`docs/hooks.md`, JavaScript scripts and The script API): the fixture scripts in `Fixtures` run in the plugin sandbox through the registry and receive their events; `arch.tabs.get` without `tabs` lacks titles and addresses; `arch.tabs.list` and `get` reach only the tabs the hook's filter covers in the event's Persona, never agent tabs, and for a hook with `agent` show no title or address of a tab whose address or committed document, which the registry gives the run, is on a site excluded from AI; a rename of a tab outside the filter is refused; a rename goes through the browser host under the suggested name rules with the run's cause, is only reported in a test, belongs to the run's document, and resolves false once the tab shows another one; a timed-out or canceled run ends its instance, a held instance does not stop for being idle, and a run releases its instance after it; what a listener throws, as the run's message; and the syntax check.
import Agent
import AI
import Events
import Foundation
import Plugins
import Testing
@testable import Hooks

/// A fixture script's bytes.
private func fixture(_ name: String) throws -> String {
    try String(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"), encoding: .utf8)
}

/// The probe tabs that `report.js` asks for.
private enum Probe {
    static let covered = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    static let otherSpace = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
    static let otherPersona = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
    static let agent = UUID(uuidString: "00000000-0000-0000-0000-0000000000C4")!
    static let excluded = UUID(uuidString: "00000000-0000-0000-0000-0000000000C5")!
}

/// The registry's fake host's tabs as plugins see them, with titles, and renames under the suggested name rules: a tab takes a name for the document it shows while the user has not named it. It lists agent tabs too, so the tests show that the run's tabs leave them out. A tab in `shownURLs` shows that address, as a WebKit tab shows a navigation's before it commits, while the registry's host and the title keep the committed one.
@MainActor
final class FakePluginHost: PluginBrowserHost {
    struct Rename: Equatable {
        var tab: UUID
        var name: String?
        var document: URL?
        var cause: BrowserEventCause
        var applying: Bool
    }

    let tabs: FakeHookHost
    var userNamed: Set<UUID> = []
    var shownURLs: [UUID: URL] = [:]
    private(set) var suggested: [UUID: String] = [:]
    private(set) var renames: [Rename] = []

    init(tabs: FakeHookHost) {
        self.tabs = tabs
    }

    func tabs(in persona: PersonaID) -> [PluginTab] {
        tabs.openTabs.filter { $0.personaID == persona }.map {
            PluginTab(id: $0.id, spaceID: $0.spaceID, title: "Title of \($0.url?.path ?? "")", url: shownURLs[$0.id] ?? $0.url, engine: $0.engine, isPinned: $0.kind == .pinned,
                      isSelected: false, kind: $0.kind, documentID: $0.documentID)
        }
    }

    func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool {
        renames.append(Rename(tab: id, name: name, document: document, cause: cause, applying: applying))
        guard let tab = tabs.tab(id), !userNamed.contains(id), let document, tab.url?.hookDocument == document.hookDocument else { return false }
        if applying { suggested[id] = name.flatMap(PluginTab.name(from:)) }
        return true
    }
}

/// The real runner, recording each invocation and outcome, since the registry keeps only a failed run's first 200 characters.
@MainActor
final class RecordingRunner: HookScriptRunning {
    let runner: HookScriptRunner
    private(set) var invocations: [HookInvocation] = []
    private(set) var outcomes: [HookRunOutcome] = []

    init(_ runner: HookScriptRunner) {
        self.runner = runner
    }

    func run(_ invocation: HookInvocation) async -> HookRunOutcome {
        invocations.append(invocation)
        let outcome = await runner.run(invocation)
        outcomes.append(outcome)
        return outcome
    }

    func cancel(run: UUID) {
        runner.cancel(run: run)
    }
}

extension HookRunOutcome {
    /// A failed run's message.
    var failure: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }

    var code: String? {
        if case .failed(let code, _) = self { return code }
        return nil
    }

    var actions: [AgentRunAction]? {
        if case .completed(let actions, _) = self { return actions }
        return nil
    }

    var isTimedOut: Bool {
        if case .timedOut = self { return true }
        return false
    }

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

extension PluginValue {
    subscript(_ key: String) -> PluginValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    var array: [PluginValue]? {
        if case .array(let items) = self { return items }
        return nil
    }
}

@MainActor @Suite struct HookScriptRunnerTests {
    private let harness = RegistryHarness()
    private let plugins: FakePluginHost
    private let recorder: RecordingRunner
    private let pageLoads = HookTrigger.pageLoaded(loads: .every, includesRestoredTabs: false)

    init() {
        plugins = FakePluginHost(tabs: harness.host)
        let settings = harness.service.settings
        recorder = RecordingRunner(HookScriptRunner(host: plugins, allowsAI: { settings.allowsAI(on: $0) }))
        harness.javaScriptRunner = recorder
    }

    private var runner: HookScriptRunner { recorder.runner }

    /// Starts the registry with the real runner and adds the hook with the fixture's script.
    private func add(_ hook: Hook, fixture name: String) async throws -> Hook {
        if harness.registry == nil { try await harness.start() }
        return try harness.add(hook, script: try fixture(name))
    }

    /// Loads the tab and waits for the run's outcome.
    private func outcome(loading tab: BrowserTabRef) async throws -> HookRunOutcome {
        let count = recorder.outcomes.count
        harness.load(tab)
        try #require(await eventually(within: .seconds(20)) { recorder.outcomes.count > count })
        return recorder.outcomes[count]
    }

    /// The report `report.js` fails with.
    private func report(of outcome: HookRunOutcome) throws -> PluginValue {
        let message = try #require(outcome.failure)
        return try JSONDecoder().decode(PluginValue.self, from: Data(message.utf8))
    }

    /// An invocation of the hook for a page load in the tab, outside the registry, as tests that drive the runner alone make it.
    private func invocation(of hook: Hook, script: String, loading tab: BrowserTabRef, documents: [UUID: URL]? = nil, applying: Bool = true,
                            timeout: Duration = .seconds(20)) -> HookInvocation {
        var hook = hook
        hook.script = .javaScript(digest: HookStore.digest(of: Data(script.utf8)), generated: false)
        let event = BrowserEvent(id: UUID(), sequence: 1, date: Date(), payload: .pageLoaded(tab: tab, isRestore: false, isFirstLoadAfterOpen: true), cause: nil)
        let run = UUID()
        let view = event.view(.hook(tabs: hook.grant.permissions.contains(.tabs), allowsAI: nil))!
        return HookInvocation(hook: hook, run: run, personaID: tab.personaID, event: view, cause: BrowserEventCause(origin: .hookRun(hook: hook.id, run: run), hookChain: [hook.id]),
                              deadline: .now + timeout, appliesActions: applying, script: Data(script.utf8), tabs: [tab.id], eventTab: tab.id,
                              documents: documents ?? [tab.id: tab.url!], closedTab: nil, knownProviders: [:], requestDidEnd: { _ in })
    }

    @Test func theEnabledTidyPresetRunsItsGeneratedFirstLoadScriptOncePerEngine() async throws {
        defer { harness.cleanUp() }
        var requests: [AgentRunRequest] = []
        let real = HookScriptRunner(host: plugins, allowsAI: { _ in true }) { request, _ in
            requests.append(request)
            guard let tab = request.tabs.first else { return AgentRunResult(status: .refused) }
            return AgentRunResult(status: .completed, actions: [.renamedTab(tab: tab, name: "Fixture title")], reply: "Done")
        }
        let recording = RecordingRunner(real)
        harness.javaScriptRunner = recording
        let registry = try await harness.start()
        let preset = try harness.add(HookPresets.tidyTabNames, script: AgentHookTemplate.script(for: .pageLoaded))
        registry.resume(preset.id)
        var web = harness.tab("/web")
        web.documentID = UUID()
        var chromium = harness.tab("/chromium", kind: .pinned)
        chromium.engine = .chromium
        chromium.documentID = UUID()
        harness.load(harness.tab("/restored"), restore: true)
        harness.load(harness.tab("/revisited"), first: false)
        harness.load(web)
        harness.load(chromium)
        try #require(await eventually(within: .seconds(20)) { recording.outcomes.count == 2 })
        #expect(Set(requests.flatMap(\.tabs)) == [web.id, chromium.id])
        #expect(requests.contains { $0.documentIDs[web.id] == web.documentID })
        #expect(requests.contains { $0.documentIDs[chromium.id] == chromium.documentID })
        #expect(requests.allSatisfy { $0.options == preset.agent && $0.knownProviders?[harness.provider.id] == HookKnownProvider(harness.provider).destination })
        #expect(recording.outcomes.allSatisfy { $0.actions?.count == 1 })
        #expect(harness.entries(of: preset.id).isEmpty)
    }

    @Test func theGeneratedCloseScriptPreviewsOnlyTheTabsLeftInTheSpace() async throws {
        defer { harness.cleanUp() }
        var call: AgentRunRequest?
        harness.javaScriptRunner = HookScriptRunner(host: plugins, allowsAI: { _ in true }) { request, _ in
            call = request
            return AgentRunResult(status: .completed, reply: "Preview reply")
        }
        let registry = try await harness.start()
        var draft = instantHook("Close preview", .tabClosed(reasons: [.user]))
        let options = AgentRunOptions(prompt: "Name the remaining tab.", model: .tier(.fast), tools: ["rename_tab"])
        AgentHookTemplate.configure(&draft, options: options, dailyLimit: 20, delay: .zero, generated: true)
        let selected = harness.tab("/selected"), elsewhere = harness.tab("/home", space: HookIDs.home)
        var left = harness.tab("/left")
        left.documentID = UUID()
        [selected, left, elsewhere].forEach(harness.host.show)
        let result = await registry.testDraft(draft, script: Data(AgentHookTemplate.script(for: .tabClosed).utf8), onTab: selected.id, applying: false)
        guard case .finished(.completed(_, let use)) = result else { Issue.record("The generated script failed: \(result)"); return }
        let request = try #require(call)
        #expect(request.documentIDs[left.id] == left.documentID)
        #expect(request.tabs == [left.id] && request.options.closedTab == selected.id && request.options.dryRun)
        #expect(request.options.model == options.model && request.options.prompt == options.prompt)
        #expect(request.knownProviders?[harness.provider.id] == HookKnownProvider(harness.provider).destination)
        #expect(request.closedTab?.url == selected.url && use?.reply == "Preview reply")
        #expect(registry.hooks.isEmpty && harness.host.tab(selected.id) != nil)
        #expect(!harness.service.features.contains { $0.id == request.feature })
        #expect(!FileManager.default.fileExists(atPath: harness.folder.appendingPathComponent("hooks.json").path))
    }

    @Test func aJavaScriptAgentCallUsesTheSavedRouteAndTheInvocationsAuthority() async throws {
        defer { harness.cleanUp() }
        let tab = harness.tab("/article", id: Probe.covered)
        let grant = AgentRunGrant(tools: ["rename_tab"], maximumRecord: .none, returnsReply: false)
        let options = AgentRunOptions(prompt: "Suggest a name", model: .tier(.fast), tools: ["rename_tab"])
        let hook = instantHook("Name this tab", pageLoads, grant: HookGrant(permissions: [.agent], agent: grant), agent: options)
        let script = """
        arch.events.on("pageLoaded", async (event) => {
          const options = { prompt: "Name the tab", model: { tier: "fast" } };
          const wrong = await arch.agent.run({...options, model: {tier: "deep"}});
          const closed = await arch.agent.run({...options, closedTab: event.tab.id});
          const broad = await arch.agent.run({...options, tabAccess: "page"});
          if ([wrong, closed, broad].some(result => result.code !== "notGranted")) throw Error("unexpected grant");
          const result = await arch.agent.run(options);
          if (result.status !== "completed" || result.reply !== undefined) throw Error("unexpected reply");
        });
        """
        var requests: [AgentRunRequest] = []
        let runner = HookScriptRunner(host: plugins, allowsAI: { _ in true }) { request, _ in
            requests.append(request)
            return AgentRunResult(status: .completed, actions: [.renamedTab(tab: tab.id, name: "Article")], reply: "private reply",
                                  model: AIModelRef(provider: AIProviderID(rawValue: "fixture"), model: "model"),
                                  usage: AIUsage(inputTokens: 4, outputTokens: 2))
        }
        var run = invocation(of: hook, script: script, loading: tab, applying: false)
        run.isTest = true
        let result = await runner.run(run)
        guard case .completed(let actions, let use) = result else { Issue.record("Script failed: \(result.failure ?? "unknown")"); return }
        #expect(actions == [.renamedTab(tab: tab.id, name: "Article")])
        #expect(use?.usage == AIUsage(inputTokens: 4, outputTokens: 2))
        try #require(requests.count == 1)
        let request = requests[0]
        #expect(request.tabs == [tab.id] && request.allowedTabs == run.tabs && request.documents == run.documents)
        #expect(request.origin == .test(hook: hook.id) && request.promptSource == .user && request.feature == .agentHook(hook.id))
        #expect(request.options.dryRun && request.options.tools == ["rename_tab"] && request.options.tabAccess == .title)
        #expect(request.knownProviders == run.knownProviders && request.grant == grant)
    }

    @Test func anAgentCallEndsWithTheScriptAndCannotAttachToTheNextInvocation() async throws {
        defer { harness.cleanUp() }
        let tab = harness.tab("/article", id: Probe.covered)
        let options = AgentRunOptions(prompt: "Inspect", model: .tier(.fast), tools: [])
        let grant = AgentRunGrant(tools: [])
        let hook = instantHook("Inspect", pageLoads, grant: HookGrant(permissions: [.agent], agent: grant), agent: options)
        let script = """
        arch.events.on("pageLoaded", async (event) => {
          void arch.agent.run(event.hook.agent).catch(() => {});
          await arch.tabs.list();
        });
        """
        var calls = 0
        var cancelled = 0
        let runner = HookScriptRunner(host: plugins, allowsAI: { _ in true }) { _, _ in
            calls += 1
            do { try await Task.sleep(for: .seconds(20)) } catch { cancelled += 1 }
            return AgentRunResult(status: .cancelled)
        }
        let outcome = await runner.run(invocation(of: hook, script: script, loading: tab))
        #expect(outcome.actions == [])
        #expect(await eventually { cancelled == 1 })
        #expect(calls == 1 && runner.keptInstanceCount == 0)
        var denied = hook
        denied.grant.permissions = []
        let check = #"arch.events.on("pageLoaded", async () => { if (arch.agent !== undefined) throw Error("agent available"); });"#
        #expect(await runner.run(invocation(of: denied, script: check, loading: tab)).actions == [])
        #expect(calls == 1)
    }

    // MARK: Events and tabs

    @Test func aScriptInTheSandboxReceivesItsEventAndWithoutTabsNoTitlesOrAddresses() async throws {
        defer { harness.cleanUp() }
        let hook = try await add(instantHook("Report", pageLoads, grant: HookGrant(permissions: [])), fixture: "report.js")
        let tab = harness.tab("/page", id: Probe.covered)
        let report = try report(of: try await outcome(loading: tab))
        let event = try #require(report["event"])
        #expect(event["kind"] == .string("pageLoaded"))
        #expect(event["isFirstLoadAfterOpen"] == .bool(true))
        #expect(event["tab"]?["id"] == .string(tab.id.uuidString))
        #expect(event["tab"]?["engine"] == .string("webkit"))
        // Without `tabs`, the event has no address.
        #expect(event["tab"]?["url"] == nil)
        #expect(event["hook"] == .object(["id": .string(hook.id.uuidString), "name": .string("Report"), "agent": .null]))
        if case .string(let date)? = event["date"] { #expect(ISO8601DateFormatter().date(from: date) != nil) } else { Issue.record("The event has no date.") }
        let listed = try #require(report["list"]?.array)
        #expect(listed.count == 1)
        #expect(listed[0]["id"] == .string(tab.id.uuidString) && listed[0]["kind"] == .string("open") && listed[0]["spaceId"] == .string(HookIDs.work.uuidString))
        #expect(listed[0]["title"] == nil && listed[0]["url"] == nil)
        #expect(report["get"]?[Probe.covered.uuidString]?["title"] == nil && report["get"]?[Probe.covered.uuidString]?["url"] == nil)
    }

    @Test func tabCallsReachOnlyTheTabsTheFilterCoversInTheEventsPersona() async throws {
        defer { harness.cleanUp() }
        _ = try await add(instantHook("Report", pageLoads, filter: BrowserEventFilter(scope: .places([.space(HookIDs.work)])), grant: HookGrant(permissions: [.tabs])),
                          fixture: "report.js")
        let covered = harness.tab("/covered", id: Probe.covered)
        [harness.tab("/home", id: Probe.otherSpace, space: HookIDs.home),
         harness.tab("/other", id: Probe.otherPersona, persona: HookIDs.otherPersona, space: HookIDs.other),
         harness.tab("/agent", id: Probe.agent, kind: .agent)].forEach(harness.host.show)
        let report = try report(of: try await outcome(loading: covered))
        #expect(report["event"]?["tab"]?["url"] == .string("https://example.org/covered"))
        let listed = try #require(report["list"]?.array)
        #expect(listed.map { $0["id"] } == [.string(Probe.covered.uuidString)])
        #expect(listed[0]["title"] == .string("Title of /covered") && listed[0]["url"] == .string("https://example.org/covered"))
        let got = try #require(report["get"])
        #expect(got[Probe.covered.uuidString]?["title"] == .string("Title of /covered"))
        for outside in [Probe.otherSpace, Probe.otherPersona, Probe.agent, Probe.excluded] {
            #expect(got[outside.uuidString] == .null)
        }
        // While a WebKit navigation waits to commit, the tab gives the run's document, which its renames belong to, not the navigation's address.
        plugins.shownURLs[Probe.covered] = URL(string: "https://example.net/next")
        let waiting = try self.report(of: try await outcome(loading: covered))
        #expect(waiting["list"]?.array?.first?["url"] == .string("https://example.org/covered"))
    }

    @Test func anAgentHookSeesNoTitleOrAddressOfATabOnAnExcludedSite() async throws {
        defer { harness.cleanUp() }
        harness.service.settings.excludedSites.append(AISitePattern("excluded.example"))
        _ = try await add(instantHook("Report", pageLoads, grant: HookGrant(permissions: [.tabs, .agent])), fixture: "report.js")
        harness.host.show(harness.tab("/secret", id: Probe.excluded, host: "excluded.example"))
        let report = try report(of: try await outcome(loading: harness.tab("/allowed", id: Probe.covered)))
        let got = try #require(report["get"])
        #expect(got[Probe.covered.uuidString]?["url"] == .string("https://example.org/allowed"))
        let excluded = try #require(got[Probe.excluded.uuidString])
        #expect(excluded["id"] == .string(Probe.excluded.uuidString))
        #expect(excluded["title"] == nil && excluded["url"] == nil)
        #expect(report["list"]?.array?.count == 2)

        // The tab now shows an allowed address while its committed document is still on the excluded site, as it shows that page's title until the next page commits. The registry gives the run that document, which keeps the tab's title and address out.
        plugins.shownURLs[Probe.excluded] = URL(string: "https://example.org/next")
        let leaving = try self.report(of: try await outcome(loading: harness.tab("/allowed", id: Probe.covered)))
        #expect(recorder.invocations.last?.documents[Probe.excluded] == URL(string: "https://excluded.example/secret"))
        let listed = try #require(leaving["list"]?.array?.first { $0["id"] == .string(Probe.excluded.uuidString) })
        #expect(listed["title"] == nil && listed["url"] == nil)
        #expect(leaving["get"]?[Probe.excluded.uuidString]?["title"] == nil && leaving["get"]?[Probe.excluded.uuidString]?["url"] == nil)
    }

    // MARK: Renames

    @Test func aRenameFollowsTheSuggestedNameRulesWithTheRunsCauseAndDocument() async throws {
        defer { harness.cleanUp() }
        let hook = try await add(instantHook("Rename", pageLoads, grant: HookGrant(permissions: [.tabsRename])), fixture: "rename.js")
        let tab = harness.tab("/a#top", id: Probe.covered)
        let outcome = try await outcome(loading: tab)
        #expect(outcome.actions == [.renamedTab(tab: tab.id, name: "Named")])
        let rename = try #require(plugins.renames.last)
        let invocation = try #require(recorder.invocations.last)
        #expect(rename.tab == tab.id && rename.name == "  Named  \nsecond line" && rename.document == tab.url && rename.applying)
        #expect(rename.cause == invocation.cause && rename.cause.hookChain == [hook.id])
        #expect(plugins.suggested[tab.id] == "Named")

        // The user's own name wins, and the script's rename resolves false.
        plugins.userNamed.insert(tab.id)
        #expect(try await self.outcome(loading: tab).failure == "notTaken")
    }

    @Test func aTestReportsARenameWithoutApplyingIt() async throws {
        defer { harness.cleanUp() }
        let hook = try await add(instantHook("Rename", pageLoads, grant: HookGrant(permissions: [.tabsRename])), fixture: "rename.js")
        let tab = harness.tab("/a", id: Probe.covered)
        harness.host.show(tab)
        guard case .finished(let outcome) = await harness.registry.test(hook.id, onTab: tab.id, applying: false) else {
            Issue.record("The test did not run.")
            return
        }
        #expect(outcome.actions == [.renamedTab(tab: tab.id, name: "Named")])
        #expect(plugins.renames.map(\.applying) == [false])
        #expect(plugins.suggested.isEmpty)
    }

    @Test func aRenameBelongsToTheRunsDocumentAndResolvesFalseOnceTheTabShowsAnother() async throws {
        defer { harness.cleanUp() }
        let script = try fixture("rename.js")
        let hook = instantHook("Rename", pageLoads, grant: HookGrant(permissions: [.tabsRename]))
        let shown = harness.tab("/b", id: Probe.covered)
        harness.host.show(shown)
        let outcome = await runner.run(invocation(of: hook, script: script, loading: shown, documents: [shown.id: URL(string: "https://example.org/a")!]))
        #expect(outcome.failure == "notTaken")
        #expect(plugins.renames.last?.document == URL(string: "https://example.org/a"))
        // A tab without a document for the run takes no name, and the host is not asked.
        let count = plugins.renames.count
        #expect(await runner.run(invocation(of: hook, script: script, loading: shown, documents: [:])).failure == "notTaken")
        #expect(plugins.renames.count == count)
    }

    @Test func aScriptCannotInspectOrRenameAReplacementDocumentAtTheSameAddress() async throws {
        defer { harness.cleanUp() }
        let hook = instantHook("Inspect and rename", pageLoads, grant: HookGrant(permissions: [.tabs, .tabsRename]))
        var tab = harness.tab("/a", id: Probe.covered)
        let captured = UUID()
        tab.documentID = captured
        var listing = invocation(of: hook, script: try fixture("report.js"), loading: tab)
        listing.documentIDs = [tab.id: captured]
        var rename = invocation(of: hook, script: try fixture("rename.js"), loading: tab)
        rename.documentIDs = listing.documentIDs
        tab.documentID = UUID()
        harness.host.show(tab)
        let result = try report(of: await runner.run(listing))
        #expect(result["get"]?[Probe.covered.uuidString] == .null && result["list"]?.array?.isEmpty == true)
        #expect(await runner.run(rename).failure == "notTaken")
        #expect(plugins.renames.isEmpty)
    }

    @Test func aRenameOfATabOutsideTheFilterIsRefused() async throws {
        defer { harness.cleanUp() }
        let filter = BrowserEventFilter(scope: .places([.space(HookIDs.work)]))
        _ = try await add(instantHook("Refused", pageLoads, filter: filter, grant: HookGrant(permissions: [.tabsRename])), fixture: "refused.js")
        harness.host.show(harness.tab("/home", id: Probe.otherSpace, space: HookIDs.home))
        #expect(try await outcome(loading: harness.tab("/a", id: Probe.covered)).failure == "refused: notGranted")
        #expect(plugins.renames.isEmpty)

        let withoutPermission = try harness.add(instantHook("Without", pageLoads, filter: filter), script: try fixture("refused.js"))
        harness.registry.pause(harness.registry.hooks[0].id)
        let outcome = try await outcome(loading: harness.tab("/b", id: Probe.covered))
        #expect(recorder.invocations.last?.hook.id == withoutPermission.id)
        #expect(outcome.failure == "refused: permissionDenied")
    }

    // MARK: Instances, limits, and the check

    @Test func runsShareAnInstanceUntilATimeoutOrACancelEndsIt() async throws {
        defer { harness.cleanUp() }
        let script = try fixture("instances.js")
        let hook = instantHook("Instances", pageLoads, grant: HookGrant(permissions: [.tabs]))
        let tab = harness.tab("/a", id: Probe.covered)
        let hang = harness.tab("/hang", id: Probe.covered)
        harness.host.show(tab)
        #expect(await runner.run(invocation(of: hook, script: script, loading: tab)).failure == "1")
        #expect(await runner.run(invocation(of: hook, script: script, loading: tab)).failure == "2")
        #expect(runner.keptInstanceCount == 1)

        let timedOut = await runner.run(invocation(of: hook, script: script, loading: hang, timeout: .milliseconds(500)))
        #expect(timedOut.isTimedOut)
        #expect(runner.keptInstanceCount == 0)
        // A new start of the script ran the next run.
        #expect(await runner.run(invocation(of: hook, script: script, loading: tab)).failure == "1")

        let held = invocation(of: hook, script: script, loading: hang)
        async let cancelled = runner.run(held)
        try await Task.sleep(for: .milliseconds(300))
        runner.cancel(run: held.run)
        #expect(await cancelled.isCancelled)
        #expect(await runner.run(invocation(of: hook, script: script, loading: tab)).failure == "1")
    }

    /// The runner holds the instance it picks for a run until the run ends, so that the idle stop cannot end it between the pick and the event's delivery.
    @Test func aHeldInstanceDoesNotStopForBeingIdleAndARunReleasesItsInstance() async throws {
        defer { harness.cleanUp() }
        let script = try fixture("instances.js")
        let hook = instantHook("Instances", pageLoads, grant: HookGrant(permissions: [.tabs]))
        // A held instance keeps running past its idle limit until it is released.
        let id = HookScriptContext.pluginID(of: hook.id)
        let manifest = PluginManifest(id: id, name: hook.name, version: "1", summary: "", permissions: [], contributions: PluginContributions(), events: [.pageLoaded])
        let plugin = ScriptPlugin(package: PluginPackage(manifest: manifest, background: "hook.js", source: Data(script.utf8), rootURL: URL(string: "arch-plugin://\(id.rawValue)/")!),
                                  limits: ScriptPluginLimits(hang: 10, idle: 0.2))
        let stops = OrderLog()
        plugin.onStop = { stops.record("\($0)") }
        try await plugin.activate(in: HookScriptContext(hook: hook, personaID: HookIDs.persona, host: plugins, allowsAI: { _ in true }))
        plugin.isHeld = true
        try await Task.sleep(for: .milliseconds(600))
        #expect(stops.entries.isEmpty)
        plugin.isHeld = false
        #expect(await eventually(within: .seconds(5)) { stops.entries == ["idle"] })

        // After a run, the instance is no longer held, and its idle stop counts again.
        let runner = HookScriptRunner(host: plugins, allowsAI: { _ in true }, idleLimit: 0.2)
        let tab = harness.tab("/a", id: Probe.covered)
        harness.host.show(tab)
        #expect(await runner.run(invocation(of: hook, script: script, loading: tab)).failure == "1")
        #expect(await runner.run(invocation(of: hook, script: script, loading: tab)).failure == "2")
        #expect(await eventually(within: .seconds(10)) { runner.keptInstanceCount == 0 })
    }

    @Test func aFailedRunNamesWhatItsListenerThrew() async throws {
        defer { harness.cleanUp() }
        // One script, so that every run uses one instance: the page's path picks what the listener throws.
        let script = #"""
        const throws = {
          plain: () => { throw new Error("plain"); },
          typed: () => { throw new TypeError("typed"); },
          text: () => { throw "text"; },
          rejected: () => Promise.reject(42),
        };
        arch.events.on("pageLoaded", async (event) => { await throws[new URL(event.tab.url).pathname.slice(1)](); });
        """#
        let hook = instantHook("Throws", pageLoads, grant: HookGrant(permissions: [.tabs]))
        for (path, message) in [("plain", "plain"), ("typed", "TypeError: typed"), ("text", "text"), ("rejected", "42")] {
            let tab = harness.tab("/\(path)", id: Probe.covered)
            harness.host.show(tab)
            let outcome = await runner.run(invocation(of: hook, script: script, loading: tab))
            #expect(outcome.code == "scriptError" && outcome.failure == message)
        }
        #expect(runner.keptInstanceCount == 1)
    }

    @Test func aChangedScriptStartsAnInstanceOfItsOwn() async throws {
        defer { harness.cleanUp() }
        let hook = instantHook("Instances", pageLoads, grant: HookGrant(permissions: [.tabs]))
        let tab = harness.tab("/a", id: Probe.covered)
        harness.host.show(tab)
        let script = try fixture("instances.js")
        #expect(await runner.run(invocation(of: hook, script: script, loading: tab)).failure == "1")
        let changed = script + "\n// Changed.\n"
        #expect(await runner.run(invocation(of: hook, script: changed, loading: tab)).failure == "1")
        #expect(runner.keptInstanceCount == 1)
    }

    @Test func theRunnerRunsOnlyScriptsThatParseAndThatListenForTheirKind() async throws {
        defer { harness.cleanUp() }
        #expect(HookScriptRunner.problem(in: Data(#"arch.events.on("pageLoaded", () => {});"#.utf8)) == nil)
        let unfinished = try #require(HookScriptRunner.problem(in: Data("arch.events.on(".utf8)))
        #expect(unfinished.hasPrefix("The script does not parse: SyntaxError"))
        #expect(HookScriptRunner.problem(in: Data(repeating: 0x20, count: HookScriptRunner.maximumScriptSize + 1)) == "The script is larger than 256 KB.")
        #expect(HookScriptRunner.problem(in: Data([0xFF, 0xFE])) == "The script is not UTF-8 text.")

        let hook = instantHook("Check", pageLoads)
        let tab = harness.tab("/a", id: Probe.covered)
        harness.host.show(tab)
        #expect(await runner.run(invocation(of: hook, script: "arch.events.on(", loading: tab)).code == "invalidScript")
        let other = await runner.run(invocation(of: hook, script: #"arch.events.on("tabOpened", () => {});"#, loading: tab))
        #expect(other.code == "noListener")
        #expect(other.failure == "The script set no listener for pageLoaded with arch.events.on.")
        // A script has no storage, secrets, or clipboard.
        let probe = #"arch.events.on("pageLoaded", async () => { const results = []; for (const attempt of [() => arch.storage.set("a", 1), () => arch.ui.copy("a")]) { try { await attempt(); results.push("allowed"); } catch (error) { results.push(error.message); } } throw new Error(results.join()); });"#
        #expect(await runner.run(invocation(of: hook, script: probe, loading: tab)).failure == "quotaExceeded,permissionDenied")
    }
}

/// Polls the main actor until the condition holds or the time passes.
@MainActor
func eventually(within limit: Duration, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
