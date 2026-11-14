// A native window's session-folder actions use its current Persona, space and the live folder owner.
import AgentControl
import AI
import ARCHEngine
import Foundation
import Testing
@testable import Agent
@testable import Browsing

@MainActor @Suite struct SessionFolderControlsTests {
    @Test func folderCommandsFollowOnlyTheReviewedSessionAndKeepUserTabs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFolderTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("session.unreadable.json"))
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let browser = try BrowserSession(registry: registry, userDataDirectory: directory, builtInPlugins: [], cefVersion: nil)
        let host = BrowserAgentHost(session: browser)
        let service = AgentService(directory: directory, host: host, version: "test", dependencies: .init(
            location: nil, keys: UnusedFolderKeys(), peerChecks: .init(read: { _ in throw CancellationError() }, verify: { _ in throw CancellationError() }),
            identify: { _ in throw CancellationError() }, processStart: { _ in nil }, prompt: AgentGrantSheetPresenter(host: host),
            authenticator: AgentDeviceOwnerAuthentication(), allowsAI: { _ in true }, now: Date.init, processRecord: { _ in nil },
            startRunner: { _ in throw CancellationError() }, sessionRoute: { .http(pinnedModel: $0) }, apiClient: WaitingFolderClient(),
            mcpExecutable: directory, sessionFolder: { _ in directory }, agentModels: { [] }, subscriptionToolName: { _ in nil }))
        browser.agents = service
        defer { service.stop() }
        let home = try #require(browser.spaces.first)
        let other = browser.addPersona(named: "Elsewhere")
        let away = try #require(browser.spaces(in: other.id).first)
        let window = BrowserWindowModel(session: browser, record: .init(id: UUID(), frame: nil, currentSpaceID: home.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        func start(_ task: String, in space: Space) throws -> AgentSession {
            try service.startSession(.init(task: task, personaID: space.resolvedPersonaID, spaceID: space.id, attachedTabIDs: [], mode: .readOnly,
                                           model: AIModelRef(provider: .init(rawValue: "local-fixture"), model: "folder"), effort: nil))
        }
        let url = try #require(URL(string: "https://fixture.invalid/research"))
        func open(for session: AgentSession) throws -> (AgentTabInfo, TabFolder) {
            let tab = try #require(host.openAgentTab(at: url, engine: .webKit, for: .init(id: session.id, spaceID: session.spaceID, folderName: session.title)))
            return (tab, try #require(browser.folders.first { $0.agentSessionID == session.id }))
        }
        let first = try start("Research home", in: home), second = try start("Research elsewhere", in: away)
        let (kept, oldFolder) = try open(for: first), (unrelated, otherFolder) = try open(for: second)
        #expect(first.isTurnRunning && second.isTurnRunning)
        await window.perform(.show, on: oldFolder, reviewed: first)
        #expect(window.agentPanel == .session(first.id))
        #expect(window.agentSession(of: otherFolder) == nil)
        await window.perform(.show, on: otherFolder, reviewed: second)
        #expect(window.agentPanel == .session(first.id))

        // An open menu or delete confirmation becomes stale after switching Persona or handing the folder back.
        window.switchToSpace(away.id)
        await window.perform(.stop, on: oldFolder, reviewed: first)
        await window.perform(.deleteSession, on: oldFolder, reviewed: first)
        #expect(service.session(withID: first.id) === first && first.isTurnRunning)
        window.switchToSpace(home.id)
        await window.perform(.stop, on: oldFolder, reviewed: first)
        let deadline = ContinuousClock.now + .seconds(2)
        while first.isTurnRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(first.state == .stopped && first.statusText == "Stopped" && second.isTurnRunning)
        await window.perform(.keepTabs, on: oldFolder, reviewed: first)
        #expect(window.agentSession(of: oldFolder) == nil)
        #expect(browser.tabs.first { $0.id == kept.id }?.agentOwnerID == nil)
        let (toClose, replacement) = try open(for: first)
        await window.perform(.deleteSession, on: oldFolder, reviewed: first)
        await window.perform(.deleteSession, on: replacement, reviewed: second)
        #expect(service.session(withID: first.id) === first && replacement.id != oldFolder.id)
        await window.perform(.deleteSession, on: replacement, reviewed: first)
        #expect(service.session(withID: first.id) == nil && first.hasEnded)
        #expect(!browser.tabs.contains { $0.id == toClose.id } && !browser.folders.contains { $0.id == replacement.id })
        #expect(browser.tabs.contains { $0.id == kept.id && $0.agentOwnerID == nil })
        #expect(browser.folders.contains { $0.id == oldFolder.id && !$0.isAgentFolder })
        #expect(browser.tabs.contains { $0.id == unrelated.id && $0.agentOwnerID == second.id })
        #expect(!browser.hasClosedTabs && browser.undoableCloseCount == 0)
        await service.endSessionsForQuit()
        #expect(!browser.tabs.contains { $0.id == unrelated.id })
        #expect(browser.tabs.contains { $0.id == kept.id })
    }
}

private actor UnusedFolderKeys: AgentSealKeyStore {
    func key() throws -> AgentSealKey? { throw CancellationError() }
    func keyCreatingIfNeeded() throws -> AgentSealKey { throw CancellationError() }
    func record(_ key: AgentSealKey) throws { throw CancellationError() }
}

private struct WaitingFolderClient: AIClient {
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { _ in }
    }
}
