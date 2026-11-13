// `agent.json`, sealed with an HMAC-SHA256 whose key only the Keychain gives Arch, so that a program with the user's shell cannot grant itself access by editing the file (docs/agents.md, Sealed settings). The file is `{"seal": <base64>, "settings": {…}}`, the seal computed over the settings' JSON with sorted keys, members this build does not know included, so that a later build's fields do not break an earlier build's check. A file whose seal does not match, or that does not read, is renamed `agent.json.unreadable`; a key the Keychain does not give leaves the file untouched for that launch.
import AgentControl
import CryptoKit
import Foundation
import Security

/// Where the seal key lives. Tests use one in memory, so that they never touch the Keychain.
public protocol AgentSealKeyStore: AnyObject, Sendable {
    /// The stored key, or nil when the Keychain has none. Throws when the Keychain does not give it, as when the user cancels the login keychain prompt or the keychain is locked.
    func key() async throws -> SymmetricKey?
    /// The stored key, made and stored first when there is none.
    func keyCreatingIfNeeded() async throws -> SymmetricKey
}

/// Service `xyz.taeyoon.arch.agent`, one generic password item of 32 random bytes, accessible when unlocked and not synchronizable, in the login keychain as `AIKeychain` keeps provider keys. Every call runs on a queue of its own off the main thread, since a call can wait while macOS asks for the keychain password, as after each ad hoc rebuild.
public final class AgentKeychainSealKey: AgentSealKeyStore, @unchecked Sendable {
    static let service = "xyz.taeyoon.arch.agent"
    static let account = "agent.json seal"

    private let queue = DispatchQueue(label: "xyz.taeyoon.arch.agent.keychain")

    public init() {}

    public func key() async throws -> SymmetricKey? {
        try await onQueue { try self.read() }
    }

    public func keyCreatingIfNeeded() async throws -> SymmetricKey {
        try await onQueue {
            if let key = try self.read() { return key }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AgentKeychainError(status: errSecAllocate) }
            var item = self.query
            item[kSecValueData as String] = Data(bytes)
            item[kSecAttrLabel as String] = "Arch agent settings seal"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let status = SecItemAdd(item as CFDictionary, nil)
            // Another launch may have stored one in between.
            if status == errSecDuplicateItem, let key = try self.read() { return key }
            guard status == errSecSuccess else { throw AgentKeychainError(status: status) }
            return SymmetricKey(data: bytes)
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func read() throws -> SymmetricKey? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else { throw AgentKeychainError(status: errSecDecode) }
            return SymmetricKey(data: data)
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
        /// The seal matched these settings.
        case verified(AgentSettings)
        /// The seal did not match, the file did not read, or the key it was sealed with is gone; the file is now `agent.json.unreadable`.
        case replaced
        /// The Keychain did not give the key, for this reason. The file stays as it was, and only the Persona ID it names, unverified, restricts a Persona.
        case keyUnavailable(String, unverifiedAgentsPersonaID: UUID?)
    }

    let fileURL: URL
    private let keys: any AgentSealKeyStore
    /// The key, once read or made this launch.
    private var key: SymmetricKey?

    init(fileURL: URL, keys: any AgentSealKeyStore) {
        self.fileURL = fileURL
        self.keys = keys
    }

    var unreadableURL: URL { fileURL.appendingPathExtension("unreadable") }

    /// The file's settings, read without the key, for the one use an unverified file has: the Persona it names stays agent-only until the seal is checked (docs/agents.md, Sealed settings).
    func unverifiedAgentsPersonaID() -> UUID? {
        guard let data = try? Data(contentsOf: fileURL), let envelope = try? AgentJSON.decode(data) else { return nil }
        return envelope["settings"]?["agentsPersonaID"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// Reads the file and checks its seal, reading the key from the Keychain once.
    func read() async -> Reading {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .none }
        var key = self.key
        do {
            if key == nil { key = try await keys.key() }
        } catch {
            return .keyUnavailable(error.localizedDescription, unverifiedAgentsPersonaID: unverifiedAgentsPersonaID())
        }
        // The bytes are read once the key is in, so that the check covers the file as it is then.
        if let key {
            self.key = key
            if let data = try? Data(contentsOf: fileURL), let settings = Self.open(data, with: key) { return .verified(settings) }
        }
        // A file sealed with a key the Keychain no longer has can never be checked again.
        try? FileManager.default.removeItem(at: unreadableURL)
        try? FileManager.default.moveItem(at: fileURL, to: unreadableURL)
        return .replaced
    }

    /// Reads or makes the key, which every write needs.
    func prepareKey() async throws {
        if key == nil { key = try await keys.keyCreatingIfNeeded() }
    }

    var hasKey: Bool { key != nil }

    /// Writes the settings sealed. Throws without a key, which `prepareKey()` reads or makes.
    func write(_ settings: AgentSettings) throws {
        guard let key else { throw AgentSettingsFileError.noKey }
        let data = try Self.seal(settings, with: key)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// The file's bytes for settings sealed with `key`.
    static func seal(_ settings: AgentSettings, with key: SymmetricKey) throws -> Data {
        let contents = try AgentJSON(encoding: settings)
        let code = HMAC<SHA256>.authenticationCode(for: try contents.encoded(), using: key)
        return try AgentJSON.object(["seal": .string(Data(code).base64EncodedString()), "settings": contents]).encoded()
    }

    /// The settings of a file whose seal matches `key`, or nil. The comparison takes the same time however much of the seal matches.
    static func open(_ data: Data, with key: SymmetricKey) -> AgentSettings? {
        guard let envelope = try? AgentJSON.decode(data), let contents = envelope["settings"],
              let seal = envelope["seal"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
              let bytes = try? contents.encoded(),
              HMAC<SHA256>.isValidAuthenticationCode(seal, authenticating: bytes, using: key)
        else { return nil }
        return try? contents.decode(as: AgentSettings.self)
    }
}

enum AgentSettingsFileError: LocalizedError {
    case noKey

    var errorDescription: String? {
        "Arch has no key from the Keychain to protect its agent settings."
    }
}
