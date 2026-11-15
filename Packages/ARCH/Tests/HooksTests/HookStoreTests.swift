// `hooks.json` and the script folders (`docs/hooks.md`, Storage): the file read back sealed; an edited file, an earlier copy put back, and a file whose key is gone set aside; a Keychain that does not give the key leaving the file as it was until Try Again; a test migration from version 0 written at the next change; a file from a later version kept, with its unknown members and hooks written back unchanged and its unknown hooks, also those with an unknown member inside a value, listed but not run; the hook's own JSON against fixed text; a command-line provider's destination; and scripts checked by digest in folders of mode 0700.
import Agent
import AgentControl
import AI
import Events
import Foundation
import Testing
@testable import Hooks

@MainActor @Suite struct HookStoreTests {
    /// A store with one hook and its script, sealed, with the Keychain's record of the write.
    private func writeOneHook(_ harness: RegistryHarness, runsHooks: Bool = false) async throws -> Hook {
        let store = harness.store
        #expect(await store.load() != nil)
        try await store.prepareKey()
        var hook = instantHook("Names", .pageLoaded(loads: .firstAfterOpen, includesRestoredTabs: false))
        hook.script = try store.writeScript(Data("export default () => {}".utf8), for: hook)
        var settings = HookSettings()
        settings.runsHooks = runsHooks
        settings.knownProviders = [HookKnownProvider(harness.provider)]
        settings.hooks = [hook]
        try await store.save(settings).value
        return hook
    }

    @Test func settingsReadBackSealedWithTheirScripts() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let hook = try await writeOneHook(harness)
        let envelope = try AgentJSON.decode(Data(contentsOf: harness.folder.appendingPathComponent("hooks.json")))
        #expect(envelope["seal"]?.stringValue != nil)
        #expect(envelope["settings"]?["generation"] == .number(1))
        #expect(envelope["settings"]?["version"] == .number(1))
        #expect(harness.keys.generation == 1)

        let store = harness.store
        let settings = try #require(await store.load())
        #expect(store.notice == nil)
        #expect(!settings.runsHooks)
        #expect(settings.knownProviders == [HookKnownProvider(id: harness.provider.id, destination: "https://models.example.test/v1")])
        #expect(try settings.hooks.map { try AgentJSON(encoding: $0) } == [try AgentJSON(encoding: hook)])
        #expect(store.script(for: settings.hooks[0]) == Data("export default () => {}".utf8))
    }

    @Test func noFileReadsNoKeyAndGivesTheDefaults() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        harness.keys.failure = "The Keychain would ask."
        let store = harness.store
        let settings = try #require(await store.load())
        #expect(settings.runsHooks && settings.hooks.isEmpty)
        #expect(store.isReady && !store.hasFile && !store.hasKey)
    }

    @Test func anEditedFileIsSetAside() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        _ = try await writeOneHook(harness)
        let url = harness.folder.appendingPathComponent("hooks.json")
        let edited = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\"runsHooks\":false", with: "\"runsHooks\":true")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        let store = harness.store
        let settings = try #require(await store.load())
        #expect(store.notice == .setAside)
        #expect(settings.hooks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
    }

    @Test func anEarlierCopyPutBackIsSetAside() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        _ = try await writeOneHook(harness)
        let url = harness.folder.appendingPathComponent("hooks.json")
        let earlier = try Data(contentsOf: url)
        let store = harness.store
        var settings = try #require(await store.load())
        settings.hooks = []
        try await store.prepareKey()
        try await store.save(settings).value
        #expect(harness.keys.generation == 2)
        try earlier.write(to: url)
        let reread = harness.store
        #expect(try #require(await reread.load()).hooks.isEmpty)
        #expect(reread.notice == .setAside)
    }

    @Test func aFileWhoseKeyIsGoneIsSetAside() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        _ = try await writeOneHook(harness)
        harness.keys.remove()
        let store = harness.store
        #expect(try #require(await store.load()).hooks.isEmpty)
        #expect(store.notice == .setAside)
    }

    @Test func aKeychainThatDoesNotGiveTheKeyLeavesTheFileUntilTryAgain() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let hook = try await writeOneHook(harness, runsHooks: true)
        let url = harness.folder.appendingPathComponent("hooks.json")
        let bytes = try Data(contentsOf: url)
        harness.keys.failure = "The keychain is locked."
        let registry = try await harness.start()
        #expect(!registry.isReady)
        #expect(registry.notice == .keyUnavailable("The keychain is locked."))
        #expect(throws: HookStoreError.self) { try registry.add(instantHook("Later", .tabOpened), script: Data()) }
        #expect(try Data(contentsOf: url) == bytes)
        // No hook runs until the file is read.
        harness.load(harness.tab())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.javaScript.invocations.isEmpty)

        harness.keys.failure = nil
        registry.retryLoading()
        #expect(await eventually { registry.isReady })
        #expect(registry.notice == nil)
        #expect(registry.hooks.map(\.id) == [hook.id])
    }

    @Test func anEarlierVersionIsMigratedAndWrittenAtTheNextChange() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let url = harness.folder.appendingPathComponent("hooks.json")
        let sealed = SealedSettingsFile<AgentJSON>(fileURL: url, keys: harness.keys)
        try await sealed.prepareKey()
        try await sealed.write(["version": 0, "hooksOn": false, "hooks": []]).value
        // Version 0 named Run Hooks `hooksOn`.
        let migrations: [Int: HookStore.Migration] = [0: { settings in
            guard var members = settings.objectValue else { return settings }
            members["runsHooks"] = members.removeValue(forKey: "hooksOn")
            return .object(members)
        }]
        let registry = try await harness.start(migrations: migrations)
        #expect(registry.isReady)
        #expect(!registry.runsHooks)

        registry.runsHooks = true
        #expect(await eventually { (try? AgentJSON.decode(Data(contentsOf: url))["settings"]?["runsHooks"]) == .bool(true) })
        let written = try AgentJSON.decode(Data(contentsOf: url))["settings"]
        #expect(written?["version"] == .number(1))
        #expect(written?["runsHooks"] == .bool(true))
        #expect(written?["hooksOn"] == nil)
    }

    @Test func whatALaterVersionHoldsThatThisBuildDoesNotKnowIsKept() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let store = harness.store
        _ = await store.load()
        /// The hook's JSON with its script written, and `value` set at `path`.
        func members(of hook: Hook, setting value: AgentJSON? = nil, at path: [String] = []) throws -> AgentJSON {
            var hook = hook
            hook.script = try store.writeScript(Data("export default () => {}".utf8), for: hook)
            func set(_ json: AgentJSON, _ path: ArraySlice<String>) -> AgentJSON {
                guard let name = path.first, case .object(var object) = json else { return value ?? json }
                object[name] = set(object[name] ?? .object([:]), path.dropFirst())
                return .object(object)
            }
            let json = try AgentJSON(encoding: hook)
            return value == nil ? json : set(json, path[...])
        }
        let known = instantHook("Known", .tabOpened)
        // A member this build does not know inside a value would be lost at its next write, so the hook is one it cannot read.
        let inFilter = instantHook("In Filter", .tabOpened)
        let grant = AgentRunGrant(tools: ["rename_tab"], maximumRecord: .none, limits: AgentRunLimits(timeout: .seconds(20), rounds: 1, toolCalls: 2))
        let inGrant = instantHook("In Grant", .tabOpened, grant: HookGrant(permissions: [.agent], agent: grant))
        let storedInFilter = try members(of: inFilter, setting: true, at: ["filter", "futureNarrowing"])
        let storedInGrant = try members(of: inGrant, setting: ["pinnedOnly": true], at: ["grant", "agent", "futureNarrowing"])
        let futureID = UUID()
        let future: AgentJSON = ["id": .string(futureID.uuidString), "name": "From Later", "trigger": ["tabTeleported": [:]], "created": 816_000_000.0]
        let url = harness.folder.appendingPathComponent("hooks.json")
        let sealed = SealedSettingsFile<AgentJSON>(fileURL: url, keys: harness.keys)
        try await sealed.prepareKey()
        try await sealed.write(["version": 2, "runsHooks": true, "futureSetting": "kept",
                                "hooks": [try members(of: known, setting: 1, at: ["futureMember"]), storedInFilter, storedInGrant, future]]).value

        let registry = try await harness.start()
        #expect(registry.notice == .newerVersion(2))
        #expect(registry.hooks.map(\.id) == [known.id, inFilter.id, inGrant.id, futureID])
        #expect(registry.hooks[3].name == "From Later")
        #expect(registry.hooks.map(\.state) == [.active, .paused(.needsNewerArch), .paused(.needsNewerArch), .paused(.needsNewerArch)])
        #expect(!harness.service.features.contains { $0.id == .agentHook(inGrant.id) })
        // The unknown hooks neither run nor resume nor change.
        registry.resume(futureID)
        registry.resume(inFilter.id)
        #expect(registry.hooks[3].state == .paused(.needsNewerArch))
        #expect(registry.hooks[1].state == .paused(.needsNewerArch))
        #expect(throws: HookRegistryError.self) { try registry.update(registry.hooks[3], script: nil) }
        let tab = harness.tab()
        harness.host.show(tab)
        harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        #expect(await eventually { harness.javaScript.invocations.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.javaScript.invocations.map(\.hook.id) == [known.id])

        registry.pause(known.id)
        #expect(await eventually {
            (try? AgentJSON.decode(Data(contentsOf: url))["settings"]?["hooks"]?.arrayValue?.first?["state"]) == ["paused": "user"]
        })
        let settings = try #require(try AgentJSON.decode(Data(contentsOf: url))["settings"])
        #expect(settings["version"] == .number(2))
        #expect(settings["futureSetting"] == "kept")
        let hooks = try #require(settings["hooks"]?.arrayValue)
        #expect(hooks[0]["futureMember"] == .number(1))
        #expect(Array(hooks[1...]) == [storedInFilter, storedInGrant, future])

        // The file still says version 2 after this build's write.
        let next = RegistryHarness(folder: harness.folder, keys: harness.keys)
        let relaunched = try await next.start()
        #expect(relaunched.notice == .newerVersion(2))
    }

    @Test func aHooksPartsHaveFixedJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func text(_ value: some Encodable) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Bool {
            try JSONDecoder().decode(Value.self, from: encoder.encode(value)) == value
        }
        let triggers: [(HookTrigger, String)] = [
            (.tabOpened, #"{"tabOpened":{}}"#),
            (.tabClosed(reasons: [.user]), #"{"tabClosed":{"reasons":["user"]}}"#),
            (.pageLoaded(loads: .firstAfterOpen, includesRestoredTabs: false), #"{"pageLoaded":{"includesRestoredTabs":false,"loads":"firstAfterOpen"}}"#),
            (.addressChanged(changes: .newHost), #"{"addressChanged":{"changes":"newHost"}}"#),
            (.titleChanged(sources: [.page]), #"{"titleChanged":{"sources":["page"]}}"#),
            (.tabSelected, #"{"tabSelected":{}}"#),
            (.downloadFinished, #"{"downloadFinished":{}}"#),
            (.spaceSwitched(personaChangesOnly: true), #"{"spaceSwitched":{"personaChangesOnly":true}}"#),
        ]
        for (trigger, json) in triggers {
            #expect(try text(trigger) == json)
            #expect(try roundTrip(trigger))
        }
        #expect(try text(HookScript.javaScript(digest: "sha256:ab", generated: true)) == #"{"javaScript":{"digest":"sha256:ab","generated":true}}"#)
        #expect(try text(HookScript.shell(source: "/Users/me/hook.sh", digest: "sha256:cd", interpreter: HookInterpreter(path: "/bin/sh", digest: "sha256:ef")))
            == #"{"shell":{"digest":"sha256:cd","interpreter":{"digest":"sha256:ef","path":"/bin/sh"},"source":"/Users/me/hook.sh"}}"#)
        #expect(try text(HookState.active) == #""active""#)
        #expect(try text(HookState.paused(.ranTooOften)) == #"{"paused":"ranTooOften"}"#)
        #expect(try text(HookState.paused(.providerErrors)) == #"{"paused":"providerErrors"}"#)
        #expect(try roundTrip(HookState.paused(.providerErrors)))
        #expect(try roundTrip(HookState.paused(.unknownProvider)))
        #expect(try text(HookOrigin.user) == #""user""#)
        #expect(try text(HookOrigin.preset("tidyTabNames")) == #"{"preset":"tidyTabNames"}"#)
        #expect(try roundTrip(HookOrigin.preset("tidyTabNames")))
        #expect(try text(HookTiming(delay: .milliseconds(1_500), timeout: .seconds(25), runsPerDay: 300)) == #"{"delay":1.5,"runsPerDay":300,"timeout":25}"#)
        #expect(try roundTrip(HookTiming(delay: .milliseconds(1_500), timeout: .seconds(25), runsPerDay: 300)))
        #expect(try text(HookGrant(permissions: [.tabsRename])) == #"{"permissions":["tabs.rename"]}"#)
        #expect(try text(HookKnownProvider(id: AIProviderID(rawValue: "P"), destination: "https://api.example.com/v1")) == #"{"destination":"https://api.example.com/v1","id":"P"}"#)
        // The defaults of each trigger's timing.
        #expect(HookTiming(for: .pageLoaded(loads: .newAddress, includesRestoredTabs: false)).delay == .milliseconds(1_500))
        #expect(HookTiming(for: .titleChanged(sources: [.page])).delay == .seconds(1))
        #expect(HookTiming(for: .tabOpened) == HookTiming(delay: .zero, timeout: .seconds(30), runsPerDay: 500))
    }

    @Test func aCommandLineProvidersDestinationCoversWhatCanSendItsRequestsElsewhere() {
        let tool = AICommandLineConfiguration(executable: URL(fileURLWithPath: "/usr/local/bin/claude"), agent: .claudeCode)
        let provider = AIProviderConfiguration(name: "Claude Code", kind: .commandLine(tool))
        let destination = HookKnownProvider(provider).destination
        #expect(destination.hasPrefix("/usr/local/bin/claude sha256:"))
        func edited(_ change: (inout AICommandLineConfiguration) -> Void) -> String {
            var edited = tool
            change(&edited)
            var changed = provider
            changed.kind = .commandLine(edited)
            return HookKnownProvider(changed).destination
        }
        #expect(edited { $0.environment["ANTHROPIC_BASE_URL"] = "https://elsewhere.example.test" } != destination)
        #expect(edited { $0.arguments = ["--settings", "/tmp/elsewhere.json"] } != destination)
        #expect(edited { $0.agent = .codex } != destination)
        #expect(edited { $0.executable = URL(fileURLWithPath: "/opt/elsewhere/claude") } != destination)
        // What decides no destination leaves it as it was.
        #expect(edited { $0.runsWithoutTools = true } == destination)
        #expect(HookKnownProvider(AIProviderConfiguration(name: "API", kind: .http(AIHTTPConfiguration(format: .messages, baseURL: URL(string: "https://api.example.test/v1")!,
                                                                                                         headers: ["anthropic-version": "1"])))).destination
            == "https://api.example.test/v1")
    }

    @Test func scriptsLiveInPrivateFoldersAndRunOnlyWhileTheirDigestMatches() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let store = harness.store
        _ = await store.load()
        var hook = instantHook("Script", .tabOpened)
        hook.script = try store.writeScript(Data("one".utf8), for: hook)
        #expect(hook.script.digest == "sha256:7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed")
        let file = store.scriptURL(of: hook)
        #expect(file.lastPathComponent == "hook.js")
        #expect(file.deletingLastPathComponent().lastPathComponent == hook.id.uuidString)
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(folderMode == 0o700)
        #expect(store.script(for: hook) == Data("one".utf8))
        try Data("two".utf8).write(to: file)
        #expect(store.script(for: hook) == nil)
        store.removeScripts(of: hook.id)
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }
}
