// Which website data store a WebKit profile uses: the default store for a profile without a storage identifier, which keeps the data of builds before Personas, and for the adapter's tests a store that keeps nothing on disk, whose web extensions keep nothing either. The tests load no page.
import ARCHEngine
@testable import ARCHEngineWebKit
import Foundation
import Testing
import WebKit

@MainActor @Suite struct WebKitProfileTests {
    private let application: WebKitApplication

    init() throws {
        let folder = FileManager.default.temporaryDirectory
        application = try #require(WebKitEngine().makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder)) as? WebKitApplication)
    }

    @Test func aProfileWithoutStorageIdentifierUsesTheDefaultStore() throws {
        var created: (any EngineBrowserContext)?
        application.createBrowserContext(storageIdentifier: nil) { created = try? $0.get() }
        let context = try #require(created as? WebKitBrowserContext)
        #expect(context.dataStore === WKWebsiteDataStore.default())
        #expect(context.storageIdentifier == nil)
    }

    @Test func aPrivateProfileAndItsExtensionsKeepNothingOnDisk() throws {
        let context = application.makeBrowserContext(storageIdentifier: nil, dataStore: .nonPersistent())
        #expect(!context.dataStore.isPersistent)
        guard #available(macOS 15.4, *) else { return }
        let configuration = try #require(context.webExtensions).controller.configuration
        #expect(!configuration.isPersistent)
    }
}
