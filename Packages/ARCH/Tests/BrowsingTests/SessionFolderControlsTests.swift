// A native window's session-folder actions use its current Persona, space and the live folder owner.
import AgentControl
import AI
import ARCHEngine
import Foundation
import SwiftUI
import Testing
@testable import Agent
@testable import Browsing

@MainActor @Suite struct SessionFolderControlsTests {
    private func fixture(in directory: URL, client: any AIClient) throws -> (BrowserSession, BrowserAgentHost, AgentService) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("session.unreadable.json"))
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let browser = try BrowserSession(registry: registry, userDataDirectory: directory, builtInPlugins: [], cefVersion: nil)
        let host = BrowserAgentHost(session: browser)
        let service = AgentService(directory: directory, host: host, version: "test", dependencies: .init(
            location: nil, keys: UnusedFolderKeys(), peerChecks: .init(read: { _ in throw CancellationError() }, verify: { _ in throw CancellationError() }),
            identify: { _ in throw CancellationError() }, processStart: { _ in nil }, prompt: AgentGrantSheetPresenter(host: host),
            authenticator: AgentDeviceOwnerAuthentication(), allowsAI: { _ in true }, now: Date.init, processRecord: { _ in nil },
            startRunner: { _ in throw CancellationError() }, sessionRoute: { .http(pinnedModel: $0) }, apiClient: client,
            mcpExecutable: directory, sessionFolder: { _ in directory }, agentModels: { [] }, subscriptionToolName: { _ in nil }, attention: {}))
        browser.agents = service
        return (browser, host, service)
    }

    @Test func folderCommandsFollowOnlyTheReviewedSessionAndKeepUserTabs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchFolderTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, host, service) = try fixture(in: directory, client: WaitingFolderClient())
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

    @Test func spaceDotsTrackUnansweredCardsAcrossWindowsAndPersonas() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSpaceDots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (browser, _, service) = try fixture(in: directory, client: QuestionClient())
        defer { service.stop() }
        let home = try #require(browser.spaces.first)
        let work = browser.addPersona(named: "Work")
        let office = try #require(browser.spaces(in: work.id).first)
        func start(in space: Space) throws -> AgentSession {
            try service.startSession(.init(task: "Review this", personaID: space.resolvedPersonaID, spaceID: space.id,
                                           attachedTabIDs: [], mode: .readOnly, model: QuestionClient.model, effort: nil))
        }
        let first = try start(in: home), second = try start(in: home), third = try start(in: office)
        // Each row renders one window's two space symbols. Keep the same view tree as sessions change.
        func marker(_ space: Space, current: Space) -> some View {
            Color.white.frame(width: 24, height: 24)
                .modifier(AgentWaitingDot(agents: service, spaceID: space.id, isCurrent: space.id == current.id, scale: 1))
        }
        let renderer = ImageRenderer(content: VStack(spacing: 0) {
            HStack(spacing: 0) {
                marker(home, current: home)
                marker(office, current: home)
            }
            HStack(spacing: 0) {
                marker(home, current: office)
                marker(office, current: office)
            }
        }.accentColor(.red))
        func dots() -> [Bool] {
            guard let image = renderer.cgImage, image.width == 48, image.height == 48 else { return [] }
            let pixels = NSBitmapImageRep(cgImage: image)
            // Sample the center of each dot, red on the symbol's white background.
            return [(18, 6), (42, 6), (18, 30), (42, 30)].map { x, y in
                let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                return (color?.greenComponent ?? 1) < 0.8
            }
        }
        #expect(dots() == [false, false, false, false])
        try #require(await eventually { service.approvals.pending.count == 3 })
        #expect(await eventually { dots() == [false, true, true, false] })
        func answer(_ session: AgentSession) async throws {
            let card = try #require(service.approvals.pending.first { $0.ownerID == session.id })
            try #require(await service.approvals.answer(card.id, with: .answer("Continue")))
            try #require(await eventually { session.state == .running })
        }
        try await answer(third)
        #expect(await eventually { dots() == [false, false, true, false] })
        try await answer(first)
        #expect(dots() == [false, false, true, false])
        second.stop()
        #expect(await eventually { dots() == [false, false, false, false] })
        #expect(service.approvals.pending.isEmpty && first.isTurnRunning && third.isTurnRunning)
        #expect(service.sessions.map(\.id) == [first.id, second.id, third.id])
        await service.endSessionsForQuit()
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

/// Each session's first round asks once. Its reply stays open after the answer so the dot must clear within the same turn.
private struct QuestionClient: AIClient {
    static let model = AIModelRef(provider: .init(rawValue: "local-fixture"), model: "question")

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(Self.model))
            if request.messages.count == 1 {
                let call = AIToolCall(id: "ask", name: "ask_user", arguments: Data(#"{"question":"Continue?"}"#.utf8))
                continuation.yield(.toolCall(call))
                continuation.yield(.finished(.toolUse))
                continuation.finish()
            } else {
                continuation.yield(.text("Continuing"))
            }
        }
    }
}
