// Private contexts fail closed before CEF starts. These checks never initialize CEF or open a browser.
import ARCHEngine
import CEFBridge
import Foundation
import Testing
@testable import ARCHEngineChromium

@Suite struct ChromiumPrivateContextTests {
    @Test func anUnavailablePrivateContextNeverFallsBackToTheGlobalProfile() {
        let folder = FileManager.default.temporaryDirectory
        let application = ChromiumApplication(configuration: EngineApplicationConfiguration(userDataDirectory: folder, cacheDirectory: folder))
        var answered = false
        application.createEphemeralBrowserContext { result in
            answered = true
            switch result {
            case .success: Issue.record("An uninitialized engine supplied a private context")
            case .failure(let error): #expect(error is EngineBrowserContextError)
            }
        }
        #expect(answered)
    }

    @Test func aContextWithExtensionsDisabledOffersNoExtensionRuntime() {
        let context = ChromiumBrowserContext(requestContext: .global, allowsExtensions: false)
        #expect(context.extensions == nil)
    }

    @Test func theBridgeCreatesPrivateStorageWithAnEmptyIndependentCachePath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/CEFBridge/CEFBridgeRequestContext.mm"), encoding: .utf8)
        let start = try #require(source.range(of: "+ (instancetype)createEphemeralContext {"))
        let end = try #require(source.range(of: "- (void)attachContext:", range: start.upperBound..<source.endIndex))
        let factory = source[start.lowerBound..<end.lowerBound]
        #expect(factory.contains("initWithProfilePath:@\"\""))
        #expect(factory.contains("CefString(&settings.cache_path) = profile.UTF8String"))
        #expect(factory.contains("CefRequestContext::CreateContext(settings, readiness)"))
        #expect(!factory.contains("GetGlobalContext"))
    }
}
