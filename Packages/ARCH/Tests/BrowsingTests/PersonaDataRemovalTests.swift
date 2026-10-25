// The removal pass at launch: a deleted Persona's plugin folder goes at once, and the Persona stays listed until every engine that keeps Persona storage reports its data removed.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@Suite struct PersonaDataRemovalTests {
    @Test func anIDLeavesTheListOnceBothEnginesRemovedItsData() {
        let webKit = StubEngine(kind: .webKit), chromium = StubEngine(kind: .chromium)
        let removal = PersonaDataRemoval(ids: [personaA, personaB], registry: registry(webKit, chromium), configuration: configuration, directory: emptyDirectory)
        var removals = 0
        removal.didRemove = { removals += 1 }
        #expect(webKit.requests == [personaA, personaB])
        #expect(chromium.requests == [personaA, personaB])
        webKit.report(true)
        #expect(removal.pendingIDs == [personaA, personaB])
        chromium.report(true)
        #expect(removal.pendingIDs.isEmpty)
        #expect(removals == 2)
    }

    @Test func anIDStaysWhileAnEngineCouldNotRemoveItsData() {
        let webKit = StubEngine(kind: .webKit), chromium = StubEngine(kind: .chromium)
        let removal = PersonaDataRemoval(ids: [personaA], registry: registry(webKit, chromium), configuration: configuration, directory: emptyDirectory)
        webKit.report(true)
        chromium.report(false)
        #expect(removal.pendingIDs == [personaA])
    }

    @Test func anIDStaysWhileAnEngineIsNotRegistered() {
        let webKit = StubEngine(kind: .webKit)
        let removal = PersonaDataRemoval(ids: [personaA], registry: registry(webKit), configuration: configuration, directory: emptyDirectory)
        webKit.report(true)
        #expect(removal.pendingIDs == [personaA])
    }

    @Test func aListedPersonasPluginFolderGoesAtOnceAndOthersStay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPersonaDataRemovalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let removed = directory.appendingPathComponent("Plugins/\(personaA.uuidString)", isDirectory: true)
        let kept = directory.appendingPathComponent("Plugins/\(personaB.uuidString)", isDirectory: true)
        for folder in [removed.appendingPathComponent("org.example.plugin", isDirectory: true), kept] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        _ = PersonaDataRemoval(ids: [personaA], registry: registry(), configuration: configuration, directory: directory)
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test func aPersonaDeletedWhileRunningWaitsForTheNextLaunch() {
        let webKit = StubEngine(kind: .webKit)
        let removal = PersonaDataRemoval(ids: [], registry: registry(webKit), configuration: configuration, directory: emptyDirectory)
        removal.removeAtNextLaunch(personaA)
        removal.removeAtNextLaunch(personaA)
        #expect(removal.pendingIDs == [personaA])
        #expect(webKit.requests.isEmpty)
    }
}

/// An engine that records each removal request and reports on it when the test says.
private final class StubEngine: Engine {
    let kind: EngineKind
    let capabilities: Set<EngineCapability> = []
    private(set) var requests: [UUID] = []
    private var completions: [(Bool) -> Void] = []

    init(kind: EngineKind) {
        self.kind = kind
    }

    func makeApplication(configuration: EngineApplicationConfiguration) throws -> any EngineApplication {
        throw StubError.noApplication
    }

    func removeStoredData(forStorage identifier: UUID, configuration: EngineApplicationConfiguration, completion: @escaping (Bool) -> Void) {
        requests.append(identifier)
        completions.append(completion)
    }

    /// Reports every request so far as removed, or as not removed.
    func report(_ removed: Bool) {
        completions.forEach { $0(removed) }
        completions.removeAll()
    }

    enum StubError: Error {
        case noApplication
    }
}

private func registry(_ engines: StubEngine...) -> EngineRegistry {
    let registry = EngineRegistry()
    engines.forEach(registry.register)
    return registry
}

private let configuration = EngineApplicationConfiguration(userDataDirectory: FileManager.default.temporaryDirectory,
                                                           cacheDirectory: FileManager.default.temporaryDirectory)
/// An Application Support folder without plugin folders, so no test touches a real one.
private let emptyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPersonaDataRemovalTests-empty-\(UUID().uuidString)", isDirectory: true)
private let personaA = UUID(uuidString: "4B0E7C1A-9D2F-4E63-8A15-2C7F3B9D6E01")!
private let personaB = UUID(uuidString: "4B0E7C1A-9D2F-4E63-8A15-2C7F3B9D6E02")!
