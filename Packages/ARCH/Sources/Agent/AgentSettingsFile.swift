// `agent.json`, sealed with an HMAC-SHA256 whose key only the Keychain gives Arch, so that a program with the user's shell cannot grant itself access by editing the file (docs/agents.md, Sealed settings). The file is `{"seal": <base64>, "settings": {…}}`, the seal computed over the settings' JSON with sorted keys, members this build does not know included, so that a later build's fields do not break an earlier build's check. The settings carry a generation that each write raises and that the Keychain keeps with the key, so that an earlier copy of the file put back, as one from before a Revoke, no longer opens. A file whose seal does not match, that does not read, or whose generation is below the Keychain's is renamed `agent.json.unreadable`; a key the Keychain does not give leaves the file untouched for that launch.
import AgentControl
import CryptoKit
import Foundation
import Security

/// The seal key and the generation of the last `agent.json` written with it. One Keychain item keeps both, so that a program that cannot read or change the key cannot lower the generation either, and removing the item takes the key with it.
public struct AgentSealKey: Sendable {
    public var key: SymmetricKey
    public var generation: Int

    public init(key: SymmetricKey, generation: Int = 0) {
        self.key = key
        self.generation = generation
    }
}

/// Where the seal key lives. Tests use one in memory, so that they never touch the Keychain.
public protocol AgentSealKeyStore: AnyObject, Sendable {
    /// The stored key and generation, or nil when the Keychain has none. Throws when the Keychain does not give them, as when the user cancels the login keychain prompt or the keychain is locked.
    func key() async throws -> AgentSealKey?
    /// The stored key and generation, made and stored first, at generation 0, when there are none.
    func keyCreatingIfNeeded() async throws -> AgentSealKey
    /// Stores the generation of the file just written with the key.
    func record(_ key: AgentSealKey) async throws
}

/// Service `xyz.taeyoon.arch.agent`, one generic password item of 32 random bytes followed by the generation as 8 bytes, most significant first, accessible when unlocked and not synchronizable, in the login keychain as `AIKeychain` keeps provider keys; an item of the key alone is at generation 0. Every call runs on a queue of its own off the main thread, since a call can wait while macOS asks for the keychain password, as after each ad hoc rebuild.
public final class AgentKeychainSealKey: AgentSealKeyStore, @unchecked Sendable {
    static let service = "xyz.taeyoon.arch.agent"
    static let account = "agent.json seal"

    private let queue = DispatchQueue(label: "xyz.taeyoon.arch.agent.keychain")

    public init() {}

    public func key() async throws -> AgentSealKey? {
        try await onQueue { try self.read() }
    }

    public func keyCreatingIfNeeded() async throws -> AgentSealKey {
        try await onQueue {
            if let key = try self.read() { return key }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AgentKeychainError(status: errSecAllocate) }
            let key = AgentSealKey(key: SymmetricKey(data: bytes))
            var item = self.query
            item[kSecValueData as String] = Self.data(of: key)
            item[kSecAttrLabel as String] = "Arch agent settings seal"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let status = SecItemAdd(item as CFDictionary, nil)
            // Another launch may have stored one in between.
            if status == errSecDuplicateItem, let key = try self.read() { return key }
            guard status == errSecSuccess else { throw AgentKeychainError(status: status) }
            return key
        }
    }

    public func record(_ key: AgentSealKey) async throws {
        try await onQueue {
            let status = SecItemUpdate(self.query as CFDictionary, [kSecValueData as String: Self.data(of: key)] as CFDictionary)
            guard status == errSecSuccess else { throw AgentKeychainError(status: status) }
        }
    }

    private static func data(of key: AgentSealKey) -> Data {
        key.key.withUnsafeBytes { Data($0) } + withUnsafeBytes(of: UInt64(key.generation).bigEndian) { Data($0) }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func read() throws -> AgentSealKey? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 || data.count == 40 else { throw AgentKeychainError(status: errSecDecode) }
            let generation = data.dropFirst(32).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard generation <= UInt64(Int.max) else { throw AgentKeychainError(status: errSecDecode) }
            return AgentSealKey(key: SymmetricKey(data: data.prefix(32)), generation: Int(generation))
        case errSecItemNotFound:
            return nil
        default:
            throw AgentKeychainError(status: status)
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}

/// A Keychain failure, described by the system's message for its status.
public struct AgentKeychainError: LocalizedError {
    public var status: OSStatus

    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
    }
}

/// Reads and writes `agent.json`. The service reads the file once at launch and writes it through here; only the key's read waits.
@MainActor final class AgentSettingsFile {
    /// How the file read at launch.
    enum Reading: Equatable {
        /// No file: the defaults, with nothing to check.
        case none
        /// The seal matched these settings, at the Keychain's generation or a later one.
        case verified(AgentSettings)
        /// The seal did not match, the file did not read, the key it was sealed with is gone, or it is an earlier file put back; the file is now `agent.json.unreadable`.
        case replaced
        /// The Keychain did not give the key, for this reason. The file stays as it was, and only the Persona ID it names, unverified, restricts a Persona.
        case keyUnavailable(String, unverifiedAgentsPersonaID: UUID?)
    }

    let fileURL: URL
    private let keys: any AgentSealKeyStore
    /// The key, once read or made this launch.
    private var key: SymmetricKey?
    /// The generation of the file read or written last, never below the Keychain's, so that each write's is above every earlier file's.
    private var generation = 0
    /// The Keychain's record of the last write's generation, which waits for the record before it, so that the records keep the writes' order.
    private var recording: Task<Void, any Error>?

    /// The settings member that holds the generation, which the seal covers. `AgentSettings` does not decode it.
    static let generationMember = "generation"

    init(fileURL: URL, keys: any AgentSealKeyStore) {
        self.fileURL = fileURL
        self.keys = keys
    }

    var unreadableURL: URL { fileURL.appendingPathExtension("unreadable") }

    /// The file's settings, read without the key, for the one use an unverified file has: the Persona it names stays agent-only until the seal is checked (docs/agents.md, Sealed settings). The app reads it before it creates the browser session, so that no profile of that Persona starts before.
    nonisolated static func unverifiedAgentsPersonaID(at fileURL: URL) -> UUID? {
        guard let data = try? Data(contentsOf: fileURL), let envelope = try? AgentJSON.decode(data) else { return nil }
        return envelope["settings"]?["agentsPersonaID"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    func unverifiedAgentsPersonaID() -> UUID? {
        Self.unverifiedAgentsPersonaID(at: fileURL)
    }

    /// Reads the file and checks its seal and generation, reading the key from the Keychain once.
    func read() async -> Reading {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .none }
        if key == nil {
            do {
                if let stored = try await keys.key() { use(stored) }
            } catch {
                return .keyUnavailable(error.localizedDescription, unverifiedAgentsPersonaID: unverifiedAgentsPersonaID())
            }
        }
        // The bytes are read once the key is in, so that the check covers the file as it is then. A file below the Keychain's generation is an earlier one put back.
        if let key, let data = try? Data(contentsOf: fileURL), let opened = Self.open(data, with: key), opened.generation >= generation {
            generation = opened.generation
            return .verified(opened.settings)
        }
        // A file sealed with a key the Keychain no longer has can never be checked again.
        try? FileManager.default.removeItem(at: unreadableURL)
        try? FileManager.default.moveItem(at: fileURL, to: unreadableURL)
        return .replaced
    }

    /// Reads or makes the key, which every write needs.
    func prepareKey() async throws {
        if key == nil { use(try await keys.keyCreatingIfNeeded()) }
    }

    private func use(_ stored: AgentSealKey) {
        key = stored.key
        generation = max(generation, stored.generation)
    }

    var hasKey: Bool { key != nil }

    /// Writes the settings sealed at the next generation, then has the Keychain record that generation, after which every earlier file stops opening. Throws without a key, which `prepareKey()` reads or makes. Returns the record, whose failure leaves the file written and the file before it still opening.
    func write(_ settings: AgentSettings) throws -> Task<Void, any Error> {
        guard let key else { throw AgentSettingsFileError.noKey }
        let next = generation + 1
        let data = try Self.seal(settings, generation: next, with: key)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        generation = next
        let previous = recording
        let keys = keys
        let record = Task {
            _ = await previous?.result
            try await keys.record(AgentSealKey(key: key, generation: next))
        }
        recording = record
        return record
    }

    /// The file's bytes for settings sealed with `key` at `generation`.
    static func seal(_ settings: AgentSettings, generation: Int, with key: SymmetricKey) throws -> Data {
        var members = try AgentJSON(encoding: settings).objectValue ?? [:]
        members[generationMember] = .number(Double(generation))
        let contents = AgentJSON.object(members)
        let code = HMAC<SHA256>.authenticationCode(for: try contents.encoded(), using: key)
        return try AgentJSON.object(["seal": .string(Data(code).base64EncodedString()), "settings": contents]).encoded()
    }

    /// The settings and generation of a file whose seal matches `key`, or nil; a file without a generation is at 0. The comparison takes the same time however much of the seal matches.
    static func open(_ data: Data, with key: SymmetricKey) -> (settings: AgentSettings, generation: Int)? {
        guard let envelope = try? AgentJSON.decode(data), let contents = envelope["settings"],
              let seal = envelope["seal"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
              let bytes = try? contents.encoded(),
              HMAC<SHA256>.isValidAuthenticationCode(seal, authenticating: bytes, using: key),
              let settings = try? contents.decode(as: AgentSettings.self)
        else { return nil }
        guard let member = contents[generationMember] else { return (settings, 0) }
        guard case .number(let number) = member, let generation = Int(exactly: number), generation >= 0 else { return nil }
        return (settings, generation)
    }
}

enum AgentSettingsFileError: LocalizedError {
    case noKey

    var errorDescription: String? {
        "Arch has no key from the Keychain to protect its agent settings."
    }
}
