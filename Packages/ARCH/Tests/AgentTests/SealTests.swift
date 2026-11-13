// `agent.json`'s seal (docs/agents.md, Sealed settings): sealed settings read back; a file edited without the key, one that does not read, one whose key the Keychain no longer has, and an earlier copy put back after a Revoke are renamed `agent.json.unreadable` and ignored, with outside access off and the Agents Persona ordinary; a Keychain that does not give the key leaves the file untouched, keeps outside access off and every grant unused, and keeps the recorded Agents Persona agent-only until Try Again reads the key, and the app reads that Persona without the key; until the seal is checked, new sessions start in Read Only and their end keeps Codex's copy; and members of a later build count in the seal.
import AgentControl
import CryptoKit
import Foundation
import Testing
@testable import Agent

@MainActor @Suite(.serialized) struct SealTests {
    /// Writes settings with outside access on, a grant until revoked, and an Agents Persona, through a first service.
    private func writeSettings(_ harness: Harness) async throws -> (agentsID: UUID, grantID: UUID) {
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice(duration: .untilRevoked)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        _ = try await client.callTool("session_info")
        service.stop()
        return (try #require(service.settings.agentsPersonaID), try #require(service.settings.grants.first?.id))
    }

    /// Waits until the Keychain records the generation of the file on disk.
    private func recorded(_ harness: Harness) async throws {
        let key = try #require(harness.keys.key)
        let generation = try #require(AgentSettingsFile.open(try Data(contentsOf: harness.settingsURL), with: key)?.generation)
        try await waitUntil { harness.keys.generation == generation }
    }

    @Test func sealedSettingsReadBack() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let written = try await writeSettings(harness)
        let service = try harness.makeService()
        #expect(service.state == .reading)
        #expect(harness.host.agentOnlyPersonaID == written.agentsID)
        try await harness.settled(service)
        #expect(service.state == .ready)
        #expect(service.settings.allowsOutsideClients)
        #expect(service.settings.grants.map(\.id) == [written.grantID])
        #expect(service.settings.grants.first?.lastUsedAt != nil)
        #expect(harness.socketExists)
        #expect(try await TestClient(harness.location).hello().status == .granted(AgentGrantSummary(level: .readOnly, persona: "Agents", expiry: .whenRevoked)))
    }

    @Test(arguments: ["edited", "unreadable", "keyGone"])
    func aFileThatFailsItsCheckIsRenamedAndIgnored(kind: String) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        _ = try await writeSettings(harness)
        let original = try Data(contentsOf: harness.settingsURL)
        var checkedBy = harness.keys
        switch kind {
        case "edited":
            // Another program widens the grant without the key.
            let text = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"readOnly\"", with: "\"actInAgentTabs\"")
            #expect(text.utf8.count == original.count + 6)
            try Data(text.utf8).write(to: harness.settingsURL)
        case "unreadable":
            try Data("{\"settings\":".utf8).write(to: harness.settingsURL)
        default:
            checkedBy = MemoryKeys()
        }
        let reading = try Harness(keys: checkedBy)
        defer { reading.cleanUp() }
        try FileManager.default.copyItem(at: harness.settingsURL, to: reading.settingsURL)
        let service = try reading.makeService()
        try await reading.settled(service)
        #expect(service.state == .replacedUnreadable)
        #expect(!service.settings.allowsOutsideClients)
        #expect(service.grants.isEmpty)
        #expect(reading.host.agentOnlyPersonaID == nil)
        #expect(!reading.socketExists)
        #expect(!FileManager.default.fileExists(atPath: reading.settingsURL.path))
        #expect(FileManager.default.fileExists(atPath: reading.settingsURL.appendingPathExtension("unreadable").path))
    }

    /// An outside agent with a shell keeps a copy of `agent.json` and puts it back while Arch is closed, after the user revoked its grant. The copy's seal matches, but its generation is below the one the Keychain keeps with the key.
    @Test func anEarlierCopyPutBackAfterARevokeIsRenamedAndIgnored() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let written = try await writeSettings(harness)
        try await recorded(harness)
        let copy = try Data(contentsOf: harness.settingsURL)
        let revoking = try harness.makeService()
        try await harness.settled(revoking)
        #expect(revoking.state == .ready)
        revoking.revoke(written.grantID)
        try await recorded(harness)
        revoking.stop()
        let latest = try Data(contentsOf: harness.settingsURL)
        try copy.write(to: harness.settingsURL)
        let service = try harness.makeService()
        try await harness.settled(service)
        #expect(service.state == .replacedUnreadable)
        #expect(service.grants.isEmpty)
        #expect(!service.settings.allowsOutsideClients)
        #expect(harness.host.agentOnlyPersonaID == nil)
        #expect(!harness.socketExists)
        #expect(try Data(contentsOf: harness.settingsURL.appendingPathExtension("unreadable")) == copy)
        // The file Arch wrote last still opens.
        try latest.write(to: harness.settingsURL)
        let next = try harness.makeService()
        try await harness.settled(next)
        #expect(next.state == .ready)
        #expect(next.settings.allowsOutsideClients)
        #expect(next.grants.isEmpty)
    }

    @Test func aKeyTheKeychainDoesNotGiveLeavesTheFileUntouched() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let written = try await writeSettings(harness)
        let original = try Data(contentsOf: harness.settingsURL)
        harness.keys.failure = "The user canceled the operation."
        let service = try harness.makeService()
        try await harness.settled(service)
        #expect(service.state == .keyUnavailable("The user canceled the operation."))
        #expect(!service.settings.allowsOutsideClients)
        #expect(service.grants.isEmpty)
        #expect(!harness.socketExists)
        #expect(harness.host.agentOnlyPersonaID == written.agentsID)
        // The app reads the same Persona before it creates the session.
        #expect(AgentService.recordedAgentsPersonaID(in: harness.folder) == written.agentsID)
        #expect(try Data(contentsOf: harness.settingsURL) == original)
        #expect(!service.canChangeSettings)
        await #expect(throws: (any Error).self) { try await service.setAllowsOutsideClients(false) }
        #expect(try Data(contentsOf: harness.settingsURL) == original)
        // Try Again once the Keychain gives the key.
        harness.keys.failure = nil
        service.retryReadingSettings()
        try await harness.settled(service)
        #expect(service.state == .ready)
        #expect(service.settings.grants.map(\.id) == [written.grantID])
        #expect(harness.socketExists)
    }

    /// The defaults stand in for the settings until the seal is checked, so they must neither raise a new session's mode above the user's choice nor delete a Codex thread the user kept.
    @Test func sessionsStartInReadOnlyAndKeepCodexsCopyUntilTheSealIsChecked() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let first = try await harness.makeOpenService()
        first.setNewSessionMode(.actInAgentTabs)
        first.stop()
        harness.keys.failure = "The user canceled the operation."
        let service = try harness.makeService()
        #expect(service.state == .reading)
        #expect(service.newSessionMode == .readOnly)
        #expect(service.keepsCodexCopy)
        try await harness.settled(service)
        #expect(service.state == .keyUnavailable("The user canceled the operation."))
        let persona = FakeHost.defaultPersona.id
        let space = try #require(harness.host.spaces(in: persona).first)
        let start = AgentService.SessionStart(task: "Summarize this tab", personaID: persona, spaceID: space.id, attachedTabIDs: [], mode: .actInAgentTabs, model: nil, effort: nil)
        let unchecked = try service.startSession(start)
        #expect(unchecked.mode == .readOnly)
        await service.deleteSession(unchecked.id)
        #expect(harness.runners.last?.endedKeepingThread == true)
        // Try Again reads the user's choices.
        harness.keys.failure = nil
        service.retryReadingSettings()
        try await harness.settled(service)
        #expect(service.state == .ready)
        #expect(service.newSessionMode == .actInAgentTabs)
        #expect(!service.keepsCodexCopy)
        let checked = try service.startSession(start)
        #expect(checked.mode == .actInAgentTabs)
        await service.deleteSession(checked.id)
        #expect(harness.runners.last?.endedKeepingThread == false)
    }

    @Test func membersOfALaterBuildCountInTheSeal() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let key = SymmetricKey(size: .bits256)
        let contents: AgentJSON = ["allowsOutsideClients": true, "grants": [], "laterSetting": ["kept": true]]
        let seal = HMAC<SHA256>.authenticationCode(for: try contents.encoded(), using: key)
        try AgentJSON.object(["seal": .string(Data(seal).base64EncodedString()), "settings": contents]).encoded().write(to: harness.settingsURL)
        let reading = try Harness(keys: MemoryKeys(key: key))
        defer { reading.cleanUp() }
        try FileManager.default.copyItem(at: harness.settingsURL, to: reading.settingsURL)
        let service = try reading.makeService()
        try await reading.settled(service)
        #expect(service.state == .ready)
        #expect(service.settings.allowsOutsideClients)
        #expect(AgentSettingsFile.open(try Data(contentsOf: reading.settingsURL), with: SymmetricKey(size: .bits256)) == nil)
    }

    @Test func noFileStartsWithTheDefaultsAndNeedsNoKey() async throws {
        let keys = MemoryKeys()
        keys.failure = "Locked."
        let harness = try Harness(keys: keys)
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        #expect(service.state == .ready)
        #expect(service.settings == AgentSettings())
        #expect(harness.host.agentOnlyPersonaID == nil)
        #expect(AgentService.recordedAgentsPersonaID(in: harness.folder) == nil)
        #expect(!harness.socketExists)
    }
}
