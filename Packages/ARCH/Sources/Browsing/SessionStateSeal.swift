// Seals the engines' page state that `session.json` keeps. WebKit's state holds each back-forward item's form data, including a password a page sent in a form that loaded without a redirect, so the file keeps the state encrypted with AES-GCM under a key in the login keychain, never in the clear.
import CryptoKit
import Foundation
import Security

/// Encrypts and decrypts page state with the key that `readKey` gives, which it reads once per launch. Without a key, as when the user denies the keychain prompt, the state is left out: saving writes none and loading drops it, so a tab restores at its address without its back-forward list.
final class SessionStateSeal: @unchecked Sendable {
    /// Starts each sealed state, which tells it from the unsealed state of builds before sealing.
    private static let marker = Data("ARCHSealedState1".utf8)

    private let readKey: () -> SymmetricKey?
    private let lock = NSLock()
    /// The key once read: nil before the first read, and `.some(nil)` when there is none, so that a denied prompt is not asked again this launch.
    private var key: SymmetricKey??

    init(key readKey: @escaping () -> SymmetricKey?) {
        self.readKey = readKey
    }

    /// Seals with the key in the login keychain, which the first save creates.
    static let keychain = SessionStateSeal(key: SessionStateKeychain.key)

    /// The sealed state, or nil without a key.
    func seal(_ state: Data) -> Data? {
        guard let key = currentKey(), let box = try? AES.GCM.seal(state, using: key), let combined = box.combined else { return nil }
        return Self.marker + combined
    }

    /// The state that `sealed` holds, or nil when it does not open with the key. State without the marker comes from a build before sealing and returns as it is, to be sealed when the session next saves.
    func open(_ sealed: Data) -> Data? {
        guard sealed.starts(with: Self.marker) else { return sealed }
        guard let key = currentKey(), let box = try? AES.GCM.SealedBox(combined: sealed.dropFirst(Self.marker.count)) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    private func currentKey() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        let read = readKey()
        key = .some(read)
        return read
    }
}

/// The key as one generic password item: service `xyz.taeyoon.arch.session`, account `page-state`, accessible after the first unlock, so that a save while the screen is locked still finds it, and not synchronizable. Like the AI module's keys it lives in the login keychain, which needs no entitlement.
enum SessionStateKeychain {
    static let service = "xyz.taeyoon.arch.session"
    private static let account = "page-state"

    /// The saved key, or a new one saved now when there is none. Nil when the keychain gives neither.
    static func key() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(read as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else { return nil }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            let key = SymmetricKey(size: .bits256)
            var item = query
            item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
            item[kSecAttrLabel as String] = "Arch session page state"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? key : nil
        default:
            return nil
        }
    }
}
