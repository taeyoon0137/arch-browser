// `agent.json`'s seal (docs/agents.md, Sealed settings): sealed settings read back; a file edited without the key, one that does not read, and one whose key the Keychain no longer has are renamed `agent.json.unreadable` and ignored, with outside access off and the Agents Persona ordinary; a Keychain that does not give the key leaves the file untouched, keeps outside access off and every grant unused, and keeps the recorded Agents Persona agent-only until Try Again reads the key; and members of a later build count in the seal.
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
        #expect(!harness.socketExists)
    }
}
