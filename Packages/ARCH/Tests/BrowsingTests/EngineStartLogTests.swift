// The session keeps why an engine or a Persona's profile did not start, for the debug window beside the tab close log: the engine, the Persona or none, and the engine's reason, once per launch for each reason. The engines are stand-ins, so no engine starts.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct EngineStartLogTests {
    /// An engine whose application never starts, with a reason of its own.
    private final class FailingEngine: Engine {
        struct Failure: LocalizedError {
            var errorDescription: String? { "The engine's framework did not load." }
        }

        let kind: EngineKind
        private(set) var attempts = 0
        init(kind: EngineKind) { self.kind = kind }
        let capabilities: Set<EngineCapability> = []
        let extensionRuntimeVersion: String? = nil
        func makeApplication(configuration: EngineApplicationConfiguration) throws -> any EngineApplication {
            attempts += 1
            throw Failure()
        }
        func removeStoredData(forStorage identifier: UUID, configuration: EngineApplicationConfiguration, completion: @escaping (Bool) -> Void) { completion(true) }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchEngineStartLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func anEngineThatDoesNotStartIsLoggedOnceWithItsReason() throws {
        try withDirectory { directory in
            let suite = "ArchEngineStartLogTests-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let registry = EngineRegistry(defaults: defaults)
            let chromium = FailingEngine(kind: .chromium)
            registry.register(chromium)
            registry.register(SessionTestEngine(kind: .webKit))
            registry.defaultKind = .chromium
            let session = try BrowserSession(testRegistry: registry, directory: directory)
            // A tab that asks for the engine again tries it again, and the log keeps the one reason.
            let tab = session.openTab(url: URL(string: "https://example.org/"), in: session.spaces[0].id, select: false, engine: .chromium)
            #expect(tab.engineKind == .webKit && chromium.attempts >= 2)
            let failures = session.engineStartLog.failures
            #expect(failures.count == 1)
            let failure = try #require(failures.first)
            #expect(failure.engine == .chromium && failure.personaID == nil && failure.personaName == nil)
            #expect(failure.reason == "The engine's framework did not load.")
            #expect(failure.error.hasSuffix("FailingEngine.Failure()"))
        }
    }

    @Test func aPersonasProfileThatDoesNotOpenIsLoggedWithThePersona() throws {
        try withDirectory { directory in
            let registry = EngineRegistry()
            let webKit = SessionTestEngine(kind: .webKit)
            registry.register(webKit)
            let session = try BrowserSession(testRegistry: registry, directory: directory)
            #expect(session.engineStartLog.failures.isEmpty)
            let persona = session.addPersona(named: "Work")
            webKit.unavailableStorageID = persona.id
            let space = try #require(session.spaces(in: persona.id).first)
            _ = session.openTab(url: URL(string: "https://example.org/"), in: space.id, select: false)
            _ = session.openTab(url: URL(string: "https://example.org/next"), in: space.id, select: false)
            let failures = session.engineStartLog.failures
            #expect(failures.count == 1)
            let failure = try #require(failures.first)
            #expect(failure.engine == .webKit && failure.personaID == persona.id && failure.personaName == "Work")
            #expect(failure.reason == CocoaError(.fileReadUnknown).localizedDescription)
        }
    }
}
