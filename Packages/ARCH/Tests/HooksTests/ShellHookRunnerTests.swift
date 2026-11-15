// Shell hook scripts (`docs/hooks.md`, Shell scripts): the fixture scripts in `Fixtures` receive the event on standard input and exactly the listed environment, run the checked bytes through `/dev/fd/3`, and fail with their exit status and last line of standard error; a copy changed outside Arch never runs; the interpreter is recorded by path and digest, and a replaced one pauses the hook with `scriptChanged`; Allow Shell Scripts pauses and resumes shell hooks and refuses new ones while it is off; the time limit ends the process group; standard error stays in the hook's last runs in memory only; the agent grant keeps tab access `title` until the user allows pages; and the run's tools reach only its tabs, by handle, under the hook's grant. `AgentTests` checks that the ticket binds only within the run's process tree.
import Agent
import AgentControl
import AI
import CryptoKit
import Darwin
import Events
import Foundation
import Plugins
import Testing
@testable import Hooks

/// A fixture script's bytes.
private func shellFixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"))
}

/// Stands in for the agents' service: it records each run's tools, start, and end, and keeps each open run's handler of `arch-cli`'s calls.
@MainActor
final class FakeRunChannel: AgentHookRunChannel {
    let ticket = "fixture-ticket"
    private(set) var tools: [UUID: [String]] = [:]
    private(set) var started: [UUID: pid_t] = [:]
    private(set) var closed: [UUID] = []
    private(set) var handlers: [UUID: @MainActor (AgentToolCall) async -> AgentToolResult] = [:]

    func openHookRun(_ run: UUID, tools: [String], call: @escaping @MainActor (AgentToolCall) async -> AgentToolResult) -> String {
        self.tools[run] = tools
        handlers[run] = call
        return ticket
    }

    func hookRun(_ run: UUID, didStart processID: pid_t) {
        started[run] = processID
    }

    func closeHookRun(_ run: UUID) {
        closed.append(run)
        handlers[run] = nil
    }
}

/// The real shell runner, recording each invocation and outcome.
@MainActor
final class RecordingShellRunner: HookScriptRunning {
    let runner: ShellHookRunner
    private(set) var invocations: [HookInvocation] = []
    private(set) var outcomes: [HookRunOutcome] = []

    init(_ runner: ShellHookRunner) {
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

    func takeErrorOutput(of run: UUID) -> String? {
        runner.takeErrorOutput(of: run)
    }
}

/// The values a fixture wrote on lines that start with `prefix`, such as `env` or `path`.
private func values(_ prefix: String, in output: String?) -> [String] {
    (output ?? "").split(separator: "\n").compactMap { line in
        line.hasPrefix(prefix + " ") ? String(line.dropFirst(prefix.count + 1)) : nil
    }
}

@MainActor @Suite struct ShellHookRunnerTests {
    private let harness = RegistryHarness()
    private let plugins: FakePluginHost
    private let channel = FakeRunChannel()
    /// Arch's temporary folder for the runs' working folders, and a folder of programs for PATH.
    private let temporary: URL
    private let programs: URL
    private let searchPath = "/usr/bin:/bin"
    private let pageLoads = HookTrigger.pageLoaded(loads: .every, includesRestoredTabs: false)

    init() throws {
        plugins = FakePluginHost(tabs: harness.host)
        temporary = harness.folder.appendingPathComponent("tmp", isDirectory: true)
        programs = harness.folder.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: programs, withIntermediateDirectories: true)
    }

    private func runner(searchPath: String? = nil, helpers: URL? = nil) -> ShellHookRunner {
        let path = searchPath ?? self.searchPath
        return ShellHookRunner(host: plugins, allowsAI: { _ in true }, channel: channel, helpers: helpers, temporaryFolder: temporary, loginPath: { path })
    }

    /// A shell hook whose script's interpreter is recorded as it resolves now, as the trust sheet records it.
    private func shellHook(_ script: Data, permissions: Set<HookPermission> = [.tabsRename], record: AgentRunRecord = .activity, searchPath: String? = nil) throws -> Hook {
        let resolution = try HookShellScript.inspect(script, searchPath: searchPath ?? self.searchPath).get()
        return Hook(name: "Shell", trigger: pageLoads, script: .shell(source: "/Users/fixture/hook.sh", digest: HookStore.digest(of: script), interpreter: resolution.interpreter),
                    grant: HookGrant(permissions: permissions), record: record, timing: HookTiming(delay: .zero, timeout: .seconds(20)))
    }

    /// An invocation of the hook for a page load in the tab, outside the registry.
    private func invocation(of hook: Hook, script: Data, loading tab: BrowserTabRef, timeout: Duration = .seconds(20)) -> HookInvocation {
        let event = BrowserEvent(id: UUID(), sequence: 1, date: Date(), payload: .pageLoaded(tab: tab, isRestore: false, isFirstLoadAfterOpen: true), cause: nil)
        let run = UUID()
        let view = event.view(.hook(tabs: hook.grant.permissions.contains(.tabs), allowsAI: nil))!
        return HookInvocation(hook: hook, run: run, personaID: tab.personaID, event: view, cause: BrowserEventCause(origin: .hookRun(hook: hook.id, run: run), hookChain: [hook.id]),
                              deadline: .now + timeout, appliesActions: true, script: script, tabs: [tab.id], eventTab: tab.id,
                              documents: [tab.id: tab.url!], closedTab: nil, knownProviders: [:], requestDidEnd: { _ in })
    }

    /// Starts the registry with the real shell runner and Allow Shell Scripts on.
    private func startRegistry(searchPath: String? = nil) async throws -> (HookRegistry, RecordingShellRunner) {
        let recorder = RecordingShellRunner(runner(searchPath: searchPath))
        harness.shellRunner = recorder
        let registry = try await harness.start()
        registry.setAllowsShellScripts(true)
        return (registry, recorder)
    }

    /// Loads the tab and waits for the run's outcome.
    private func outcome(loading tab: BrowserTabRef, recorder: RecordingShellRunner) async throws -> HookRunOutcome {
        let count = recorder.outcomes.count
        harness.load(tab)
        try #require(await eventually(within: .seconds(20)) { recorder.outcomes.count > count })
        return recorder.outcomes[count]
    }

    // MARK: Running

    @Test func aScriptGetsTheEventOnStandardInputAndItsCheckedBytesThroughDescriptorThree() async throws {
        defer { harness.cleanUp() }
        let script = try shellFixture("input.sh")
        let hook = try shellHook(script)
        let tab = harness.tab("/page")
        harness.host.show(tab)
        let shell = runner()
        let run = invocation(of: hook, script: script, loading: tab)
        let outcome = await shell.run(run)
        #expect(outcome.actions == [])
        let output = shell.takeErrorOutput(of: run.run)
        // The interpreter reads the bytes Arch checked from the pipe, never a file of the hook's.
        #expect(values("path", in: output) == ["/dev/fd/3"])
        let processID = try #require(channel.started[run.run])
        #expect(values("pid", in: output) == [String(processID)])
        let event = try AgentJSON.decode(Data(try #require(values("event", in: output).first).utf8))
        #expect(event["kind"] == "pageLoaded")
        #expect(event["tab"]?["handle"] == "t1" && event["tab"]?["id"]?.stringValue == tab.id.uuidString)
        // Without `tabs`, the event has no address.
        #expect(event["tab"]?["url"] == nil)
        #expect(event["hook"]?["id"]?.stringValue == hook.id.uuidString && event["hook"]?["name"] == "Shell" && event["hook"]?["agent"] == .null)
        #expect(channel.tools[run.run] == ["list_tabs", "rename_tab"] && channel.closed == [run.run])
        // The run's working folder is gone, and its error output is taken once.
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        #expect(shell.takeErrorOutput(of: run.run) == nil)
    }

    @Test func aScriptGetsExactlyTheListedEnvironment() async throws {
        defer { harness.cleanUp() }
        let script = try shellFixture("environment.awk")
        let hook = try shellHook(script)
        let tab = harness.tab()
        harness.host.show(tab)
        let helpers = URL(fileURLWithPath: "/Applications/Arch.app/Contents/Helpers", isDirectory: true)
        let shell = runner(helpers: helpers)
        let run = invocation(of: hook, script: script, loading: tab)
        #expect(await shell.run(run).actions == [])
        var environment: [String: String] = [:]
        for entry in values("env", in: shell.takeErrorOutput(of: run.run)) {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            environment[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        #expect(Set(environment.keys) == Set(HookShellScript.environmentNames))
        #expect(environment["PATH"] == "/Applications/Arch.app/Contents/Helpers:/usr/bin:/bin")
        #expect(environment["HOME"] == NSHomeDirectory())
        #expect(environment["TMPDIR"] == temporary.appendingPathComponent("Arch-Hook-\(run.run.uuidString)").path + "/")
        #expect(environment["ARCH_HOOK_ID"] == hook.id.uuidString && environment["ARCH_HOOK_EVENT"] == "pageLoaded")
        #expect(environment[AgentControlProtocol.hookTicketVariable] == channel.ticket)
    }

    @Test func aNonzeroStatusFailsTheRunWithItsLastErrorLine() async throws {
        defer { harness.cleanUp() }
        let script = try shellFixture("fails.sh")
        let tab = harness.tab()
        harness.host.show(tab)
        let shell = runner()
        let run = invocation(of: try shellHook(script), script: script, loading: tab)
        let outcome = await shell.run(run)
        #expect(outcome.code == "exitStatus" && outcome.failure == "Exited with status 3: no tab to rename")
        #expect(shell.takeErrorOutput(of: run.run) == "looking for the tab\nno tab to rename\n")
    }

    @Test func theTimeLimitEndsTheProcessGroup() async throws {
        defer { harness.cleanUp() }
        let script = try shellFixture("sleeps.sh")
        let tab = harness.tab()
        harness.host.show(tab)
        let shell = runner()
        let run = invocation(of: try shellHook(script), script: script, loading: tab, timeout: .seconds(1))
        let started = ContinuousClock.now
        #expect(await shell.run(run).isTimedOut)
        #expect(started.duration(to: .now) < .seconds(10))
        // The script's child got the group's SIGTERM too.
        let child = try #require(values("child", in: shell.takeErrorOutput(of: run.run)).first.flatMap { pid_t($0) })
        #expect(await eventually { kill(child, 0) == -1 && errno == ESRCH })
    }

    @Test func aCancelEndsTheScript() async throws {
        defer { harness.cleanUp() }
        let script = try shellFixture("sleeps.sh")
        let tab = harness.tab()
        harness.host.show(tab)
        let shell = runner()
        let run = invocation(of: try shellHook(script), script: script, loading: tab)
        let running = Task { await shell.run(run) }
        try #require(await eventually { channel.started[run.run] != nil })
        shell.cancel(run: run.run)
        #expect(await running.value.isCancelled)
    }

    // MARK: The interpreter

    @Test func theInterpreterIsRecordedByPathAndDigest() throws {
        defer { harness.cleanUp() }
        let pointer = try #require(realpath("/bin/sh", nil))
        let shell = String(cString: pointer)
        free(pointer)
        let digest = "sha256:" + SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: shell))).map { String(format: "%02x", $0) }.joined()
        let absolute = try HookShellScript.inspect(Data("#!/bin/sh\nexit 0\n".utf8), searchPath: searchPath).get()
        #expect(absolute.interpreter == HookInterpreter(path: shell, digest: digest))
        // A `/usr/bin/env` program resolves in the script's PATH through its link, and the sheet names the folder the user can write to.
        let link = programs.appendingPathComponent("fixture-sh")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/sh")
        let found = try HookShellScript.inspect(Data("#!/usr/bin/env fixture-sh\n".utf8), searchPath: "\(programs.path):\(searchPath)").get()
        #expect(found.interpreter == absolute.interpreter && found.named == link.path && found.writableFolders == [programs.path])
        if case .failure(let problem) = HookShellScript.inspect(Data("#!/usr/bin/env fixture-sh\n".utf8), searchPath: searchPath) {
            #expect(problem.sentence == "Arch cannot find fixture-sh in the PATH this script gets.")
        } else {
            Issue.record("A program outside PATH resolved.")
        }
        // The first line names one interpreter and at most one option of the allowed letters, never `env`'s options or a relative path.
        #expect(HookShellScript.interpreterLine(of: Data("#!/bin/sh -e\n".utf8)) == .path("/bin/sh", argument: "-e"))
        #expect(HookShellScript.interpreterLine(of: Data("#!/bin/sh -eux\n".utf8)) == .path("/bin/sh", argument: "-eux"))
        #expect(HookShellScript.interpreterLine(of: Data("#!/usr/bin/awk -f\n".utf8)) == .path("/usr/bin/awk", argument: "-f"))
        #expect(HookShellScript.interpreterLine(of: Data("#! /usr/bin/env  python3\n".utf8)) == .env("python3"))
        for refused in ["#!sh\n", "#!/bin/sh -e -u\n", "#!/usr/bin/env\n", "#!/usr/bin/env -S sh -e\n", "#!/usr/bin/env ./sh\n", "#!/usr/bin/env A=1 sh\n", "echo hi\n",
                        // Options that make the interpreter read its program from standard input, where the event is, or run another file or command.
                        "#!/bin/sh -s\n", "#!/bin/sh -es\n", "#!/bin/sh -\n", "#!/bin/sh --\n", "#!/bin/sh -c\n", "#!/bin/zsh -i\n", "#!/bin/bash -l\n",
                        "#!/usr/bin/python3 -i\n", "#!/usr/bin/python3 other.py\n", "#!/bin/sh e\n"] {
            #expect(HookShellScript.problem(in: Data(refused.utf8)) == HookShellScript.firstLineSentence, "\(refused)")
        }
        #expect(HookShellScript.problem(in: Data([0x23, 0x21, 0x2F, 0xFF])) == "The script is not UTF-8 text.")
        #expect(HookShellScript.problem(in: Data("#!/bin/sh\n".utf8) + Data(repeating: 0x20, count: HookShellScript.maximumSize)) == "The script is larger than 1 MB.")
    }

    @Test func aScriptWithCharactersTheTrustSheetCannotShowIsRefused() async throws {
        defer { harness.cleanUp() }
        // Carriage returns, form feeds, escapes, text direction marks, zero-width characters, and line separators other than the line feed.
        for hidden in ["\r", "\u{0B}", "\u{0C}", "\u{1B}[2K", "\u{00}", "\u{85}", "\u{202E}", "\u{2066}", "\u{200B}", "\u{FEFF}", "\u{2028}", "\u{2029}"] {
            let script = Data("#!/bin/sh\necho \"safe\(hidden)\"\n".utf8)
            #expect(HookShellScript.problem(in: script) == HookShellScript.hiddenCharacterSentence, "\(hidden.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        #expect(HookShellScript.problem(in: Data("#!/bin/sh\n\techo \"caf\u{E9}\"\n".utf8)) == nil)
        // The sheet breaks lines where the interpreter does, at line feeds only.
        #expect(HookShellScript.lines(of: "one\u{2028}still one\ntwo\r\n") == ["one\u{2028}still one", "two\r", ""])
        // The runner refuses such a copy too.
        let tab = harness.tab()
        harness.host.show(tab)
        let trusted = Data("#!/bin/sh\nexit 0\n".utf8)
        let script = Data("#!/bin/sh\necho \"done\" \u{202E}; exit 0\n".utf8)
        let outcome = await runner().run(invocation(of: try shellHook(trusted), script: script, loading: tab))
        #expect(outcome.code == "invalidScript" && outcome.failure == HookShellScript.hiddenCharacterSentence)
        #expect(channel.started.isEmpty)
    }

    @Test func aReplacedInterpreterPausesTheHookUntilTheUserTrustsItAgain() async throws {
        defer { harness.cleanUp() }
        // macOS runs Apple's shells only from their own paths, so the PATH folder holds a link to one, as a package manager's folder does.
        let program = programs.appendingPathComponent("fixture-shell")
        try FileManager.default.createSymbolicLink(atPath: program.path, withDestinationPath: "/bin/bash")
        let path = "\(programs.path):\(searchPath)"
        let (registry, recorder) = try await startRegistry(searchPath: path)
        let script = Data("#!/usr/bin/env fixture-shell\nexit 0\n".utf8)
        let hook = try harness.add(try shellHook(script, searchPath: path), script: String(decoding: script, as: UTF8.self))
        #expect(try await outcome(loading: harness.tab("/one"), recorder: recorder).actions == [])

        // A package manager's update points the link at another program.
        try FileManager.default.removeItem(at: program)
        try FileManager.default.createSymbolicLink(atPath: program.path, withDestinationPath: "/bin/zsh")
        let changed = try await outcome(loading: harness.tab("/two"), recorder: recorder)
        #expect(changed.code == "scriptChanged" && changed.failure == "Its interpreter changed.")
        #expect(await eventually { registry.hooks.first?.state == .paused(.scriptChanged) })
        // Resume cannot lift it; trusting the script again with the new interpreter does.
        registry.resume(hook.id)
        #expect(registry.hooks.first?.state == .paused(.scriptChanged))
        var trusted = try #require(registry.hooks.first)
        trusted.script = try shellHook(script, searchPath: path).script
        try registry.update(trusted, script: script)
        #expect(registry.hooks.first?.state == .active)
        #expect(registry.hooks.first?.script == trusted.script)
        #expect(try await outcome(loading: harness.tab("/three"), recorder: recorder).actions == [])
    }

    @Test func aChangedInterpreterFileIsNoLongerTheRecordedOne() throws {
        defer { harness.cleanUp() }
        // A program file that changes in place keeps its path, but not its digest; Arch only reads it here.
        let program = programs.appendingPathComponent("fixture-interpreter")
        try Data("first build".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let script = Data("#!\(program.path)\n".utf8)
        let recorded = try HookShellScript.inspect(script, searchPath: searchPath).get().interpreter
        #expect(HookShellScript.interpreterProblem(recorded, script: script, searchPath: searchPath) == nil)
        try Data("second build".utf8).write(to: program)
        #expect(HookShellScript.interpreterProblem(recorded, script: script, searchPath: searchPath) == "Its interpreter changed.")
    }

    @Test func aCopyChangedOutsideArchNeverRuns() async throws {
        defer { harness.cleanUp() }
        let (registry, recorder) = try await startRegistry()
        let script = try shellFixture("input.sh")
        let hook = try harness.add(try shellHook(script), script: String(decoding: script, as: UTF8.self))
        try Data("#!/bin/sh\necho changed\n".utf8).write(to: harness.store.scriptURL(of: hook))
        harness.load(harness.tab())
        try #require(await eventually { registry.hooks.first?.state == .paused(.scriptChanged) && registry.lastRuns[hook.id]?.last != nil })
        #expect(recorder.invocations.isEmpty)
        #expect(registry.lastRuns[hook.id]?.last?.message == "Its script changed outside Arch.")
    }

    // MARK: Allow Shell Scripts

    @Test func allowShellScriptsPausesAndResumesShellHooksAndGuardsNewOnes() async throws {
        defer { harness.cleanUp() }
        let (registry, _) = try await startRegistry()
        let script = try shellFixture("fails.sh")
        let hook = try harness.add(try shellHook(script), script: String(decoding: script, as: UTF8.self))
        let javaScript = try harness.add(Hook(name: "Script", trigger: .tabOpened))
        registry.setAllowsShellScripts(false)
        #expect(registry.hooks.first { $0.id == hook.id }?.state == .paused(.shellScriptsOff))
        #expect(registry.hooks.first { $0.id == javaScript.id }?.state == .active)
        registry.resume(hook.id)
        #expect(registry.hooks.first { $0.id == hook.id }?.state == .paused(.shellScriptsOff))
        #expect(throws: HookRegistryError.shellScriptsOff) { try registry.add(try shellHook(script), script: script) }
        registry.setAllowsShellScripts(true)
        #expect(registry.hooks.first { $0.id == hook.id }?.state == .active)
        // Outside programs never add shell hooks, and a file the runner would refuse is refused at once.
        var outside = try shellHook(script)
        outside.origin = .outsideClient(.signed(identifier: "com.example.agent", team: "ABCDE12345"), name: "Agent")
        #expect(throws: HookRegistryError.shellScriptsOff) { try registry.add(outside, script: script) }
        #expect(throws: HookRegistryError.invalidScript(HookShellScript.firstLineSentence)) { try registry.add(try shellHook(script), script: Data("echo hi\n".utf8)) }
        // `hooks.json` keeps the switch.
        let file = harness.store.fileURL
        #expect(await eventually { FileManager.default.fileExists(atPath: file.path) })
        let relaunched = RegistryHarness(folder: harness.folder, keys: harness.keys)
        #expect(try await relaunched.start().allowsShellScripts)
    }

    // MARK: Records

    @Test func standardErrorStaysInTheLastRunsInMemoryOnly() async throws {
        defer { harness.cleanUp() }
        let (registry, recorder) = try await startRegistry()
        let script = try shellFixture("fails.sh")
        let kept = try harness.add(try shellHook(script), script: String(decoding: script, as: UTF8.self))
        let failed = try await outcome(loading: harness.tab("/kept"), recorder: recorder)
        #expect(failed.code == "exitStatus")
        // The registry records a run after its runner returns.
        try #require(await eventually { registry.lastRuns[kept.id]?.last != nil })
        let summary = try #require(registry.lastRuns[kept.id]?.last)
        #expect(summary.errorOutput == "looking for the tab\nno tab to rename\n" && summary.message == "Exited with status 3: no tab to rename")
        registry.log.saveNow()
        let log = try String(contentsOf: harness.folder.appendingPathComponent("hooks-activity.json"), encoding: .utf8)
        #expect(log.contains(kept.id.uuidString) && !log.contains("no tab to rename") && !log.contains("looking for the tab"))
        // Keep Nothing keeps neither the output nor the script's words.
        registry.remove(kept.id)
        let quiet = try harness.add(try shellHook(script, record: .none), script: String(decoding: script, as: UTF8.self))
        _ = try await outcome(loading: harness.tab("/quiet"), recorder: recorder)
        try #require(await eventually { registry.lastRuns[quiet.id]?.last != nil })
        let reduced = try #require(registry.lastRuns[quiet.id]?.last)
        #expect(reduced.errorOutput == nil && reduced.message == nil && reduced.code == "exitStatus")
    }

    // MARK: Grants and tools

    @Test func theAgentGrantKeepsTitlesOnlyUntilTheUserAllowsPages() {
        let grant = AgentRunGrant(tools: ["rename_tab", "read_text", "snapshot"], tabAccess: .page, maximumRecord: .activity)
        let limited = HookShellScript.agentGrant(grant, readsPages: false)
        #expect(limited.tools == ["rename_tab"] && limited.tabAccess == .title && limited.maximumRecord == .activity)
        #expect(HookShellScript.agentGrant(grant, readsPages: true) == grant)
    }

    @Test func theRunsToolsReachOnlyItsTabsByHandle() throws {
        defer { harness.cleanUp() }
        var event = harness.tab("/event")
        event.documentID = UUID()
        let other = harness.tab("/other")
        let outside = harness.tab("/outside")
        // Sidebar order puts the other tab first; the event's tab is still t1.
        [other, event, outside].forEach(harness.host.show)
        var hook = try shellHook(try shellFixture("input.sh"), permissions: [.tabsRename])
        var run = invocation(of: hook, script: try shellFixture("input.sh"), loading: event)
        run.tabs = [event.id, other.id]
        run.documents[other.id] = other.url
        run.documentIDs = [event.id: event.documentID!]
        var tools = ShellHookRunTools(invocation: run, host: plugins, allowsAI: { _ in true })
        #expect(tools.handles == [event.id: "t1", other.id: "t2"])
        let listed = tools.call(AgentToolCall(name: "list_tabs"))
        // Without `tabs`, a tab shows no title or address.
        #expect(listed.status == .ok && listed.structured?["tabs"] == .array([
            ["handle": "t1", "kind": "open", "engine": "webKit", "pinned": false, "selected": false],
            ["handle": "t2", "kind": "open", "engine": "webKit", "pinned": false, "selected": false],
        ]))
        let renamed = tools.call(AgentToolCall(name: "rename_tab", arguments: ["tab": "t1", "name": "Event\nsecond line"]))
        #expect(renamed.status == .ok && tools.actions == [.renamedTab(tab: event.id, name: "Event")])
        #expect(plugins.renames.last == FakePluginHost.Rename(tab: event.id, name: "Event", document: event.url, cause: run.cause, applying: true))
        #expect(tools.call(AgentToolCall(name: "rename_tab", arguments: ["tab": "t9", "name": "No"])).code == "notGranted")
        #expect(tools.call(AgentToolCall(name: "read_text", arguments: ["tab": "t1"])).code == "notGranted")
        // A tab that moved to another document is stale.
        var moved = event
        moved.url = URL(string: "https://example.org/elsewhere")
        harness.host.show(moved)
        #expect(tools.call(AgentToolCall(name: "rename_tab", arguments: ["tab": "t1", "name": "Late"])).status == .stale)
        tools.end()
        #expect(tools.call(AgentToolCall(name: "list_tabs")).code == "runEnded")

        // With `tabs`, titles and the run's documents show; without `tabs.rename`, no rename is listed or run.
        hook.grant.permissions = [.tabs]
        run.hook = hook
        harness.host.show(event)
        tools = ShellHookRunTools(invocation: run, host: plugins, allowsAI: { _ in true })
        #expect(tools.names == ["list_tabs"])
        #expect(tools.call(AgentToolCall(name: "list_tabs")).structured?["tabs"] == .array([
            ["handle": "t1", "kind": "open", "engine": "webKit", "pinned": false, "selected": false, "title": "Title of /event", "url": .string(event.url!.absoluteString)],
            ["handle": "t2", "kind": "open", "engine": "webKit", "pinned": false, "selected": false, "title": "Title of /other", "url": .string(other.url!.absoluteString)],
        ]))
        #expect(tools.call(AgentToolCall(name: "rename_tab", arguments: ["tab": "t1", "name": "No"])).code == "notGranted")
    }

    @Test func aTestRunReportsItsRenamesWithoutApplyingThem() throws {
        defer { harness.cleanUp() }
        let tab = harness.tab("/preview")
        harness.host.show(tab)
        var run = invocation(of: try shellHook(try shellFixture("input.sh")), script: try shellFixture("input.sh"), loading: tab)
        run.isTest = true
        run.appliesActions = false
        let tools = ShellHookRunTools(invocation: run, host: plugins, allowsAI: { _ in true })
        let result = tools.call(AgentToolCall(name: "rename_tab", arguments: ["tab": "t1", "name": "Preview"]))
        #expect(result.status == .ok && result.text == "Would rename t1 to \u{201C}Preview\u{201D}.")
        #expect(plugins.renames.last?.applying == false && plugins.suggested[tab.id] == nil && tools.actions == [.renamedTab(tab: tab.id, name: "Preview")])
    }
}
