// Sessions in temporary profiles use process-local storage for page state and private feed addresses.
import ARCHEngine
@testable import Browsing
import CryptoKit
import Foundation
import LiveFolders

extension SessionStateSeal {
    static let fixture: SessionStateSeal = {
        let key = SymmetricKey(size: .bits256)
        return SessionStateSeal { key }
    }()
}

extension BrowserSession {
    convenience init(testRegistry: EngineRegistry, directory: URL, addresses: any LiveFolderAddressStore = InMemoryLiveFolderKeychain()) throws {
        try self.init(registry: testRegistry, userDataDirectory: directory, builtInPlugins: [], cefVersion: nil,
                      sessionSeal: .fixture, liveFolderAddresses: addresses)
    }
}
