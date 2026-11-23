// Sessions in temporary profiles use process-local storage for page state and touch no Keychain.
import ARCHEngine
@testable import Browsing
import CryptoKit
import Foundation

extension SessionStateSeal {
    static let fixture: SessionStateSeal = {
        let key = SymmetricKey(size: .bits256)
        return SessionStateSeal { key }
    }()
}

extension BrowserSession {
    /// `removeLiveFolderKeychainItems` stands in for deleting the removed live folders' Keychain items.
    convenience init(testRegistry: EngineRegistry, directory: URL, removeLiveFolderKeychainItems: @escaping @Sendable () -> Void = {}) throws {
        try self.init(registry: testRegistry, userDataDirectory: directory, builtInPlugins: [], cefVersion: nil,
                      sessionSeal: .fixture, removeLiveFolderKeychainItems: removeLiveFolderKeychainItems)
    }
}
