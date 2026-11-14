// What the agent tests share: a browser host with Personas and spaces in memory, a grant prompt and an authenticator that answer as told, a seal key in memory, a clock, a temporary folder for `agent.json`, the activity log, and the socket, and a client that runs its blocking calls off the main actor, where the service runs. The tests reach no Keychain, window, or Arch; the client is this test process, whose own code the service's peer check expects.
import AgentControl
import AI
import AppKit
import ARCHEngine
import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import Agent

@MainActor final class FakeHost: AgentBrowserHost {
    var personas: [AgentPersonaInfo]
    var spacesByPersona: [UUID: [AgentSpaceInfo]]
    var tabs: [AgentTabInfo] = []
    private(set) var agentOnlyPersonaID: UUID?
    private(set) var madeAgentsPersonas = 0
    var personasDidChange: (() -> Void)?
    var agentTabDidReport: ((_ ownerID: UUID, _ tabID: UUID, _ report: AgentTabReport) -> Void)?
    var agentTabMayLoad: ((_ ownerID: UUID, _ tabID: UUID, _ url: URL) -> Bool)?
    var agentTabMayDownload: ((_ ownerID: UUID, _ tabID: UUID, _ url: URL) -> Bool)?
    var agentPanel: AgentPanelModel?
    /// Real web contents behind some tabs, which the page script and captures reach, as in the page script tests.
    var webContents: [UUID: any EngineWebContents] = [:]
    /// What the fake engine captures for a tab in place of its web contents' capture; a tab with neither captures nothing, as Chromium may for a tab no window shows.
    var captures: [UUID: NSImage] = [:]
    var onCapture: (() -> Void)?
    /// Tabs whose capture never answers, as a busy page's or one no window shows may not.
    var hangingCaptureTabIDs: Set<UUID> = []
    /// The apps that open links, by scheme.
    var appNames: [String: String] = ["mailto": "Mail"]
    var userTabIDs: Set<UUID> = []
    var downloads: [UUID: [AgentDownloadInfo]] = [:]
    private(set) var shownTabIDs: [UUID] = []
    private(set) var shownPanels: [UUID] = []
    private(set) var openedExternally: [URL] = []

    /// The pages the fake engine serves, by address, with their titles and text; any other address loads with an empty title and no text.
    var pages: [URL: (title: String, text: String)] = [:]
    /// Server redirects, by the address that answers with the next.
    var redirects: [URL: URL] = [:]
    /// Addresses whose load never finishes, as a page that keeps loading.
    var hangingAddresses: Set<URL> = []
    /// Addresses whose document commits, so that the tab's address changes, but never finishes loading, as a page that keeps one image request open.
    var committingAddresses: Set<URL> = []
    /// Addresses that fail to load, which leaves the tab on its page.
    var failingAddresses: Set<URL> = []
    /// Tabs whose page never answers a read, as while it shows a dialog.
    var silentTabIDs: Set<UUID> = []
    /// Lets a test change the tab or turn after extraction, before the engine answers.
    var beforeReturningContent: (() -> Void)?
    var history: [AgentHistoryPage] = []
    private(set) var openedOwners: [AgentTabOwner] = []
    private(set) var closedTabIDs: [UUID] = []
    private(set) var navigations: [AgentNavigation] = []
    private var backList: [UUID: [URL]] = [:]

    nonisolated static let defaultPersona = AgentPersonaInfo(id: UUID(uuidString: "D59DAF4B-E372-4AF9-890E-455B8B3860F3")!, name: "Default")
    nonisolated static let workPersona = AgentPersonaInfo(id: UUID(), name: "Work")

    init() {
        personas = [Self.defaultPersona, Self.workPersona]
        spacesByPersona = [
            Self.defaultPersona.id: [AgentSpaceInfo(id: UUID(), name: "Home"), AgentSpaceInfo(id: UUID(), name: "Reading")],
            Self.workPersona.id: [AgentSpaceInfo(id: UUID(), name: "Office")],
        ]
    }

    func spaces(in personaID: UUID) -> [AgentSpaceInfo] { spacesByPersona[personaID] ?? [] }

    func tabs(withIDs ids: Set<UUID>) -> [AgentTabInfo] { tabs.filter { ids.contains($0.id) } }

    func agentTabs(of ownerID: UUID) -> [AgentTabInfo] { tabs.filter { $0.agentOwnerID == ownerID } }

    func openAgentTab(at url: URL, engine: EngineKind?, for owner: AgentTabOwner) -> AgentTabInfo? {
        guard spacesByPersona.values.contains(where: { $0.contains { $0.id == owner.spaceID } }) else { return nil }
        openedOwners.append(owner)
        let tab = AgentTabInfo(id: UUID(), spaceID: owner.spaceID, title: "", url: nil, isLoading: true, engine: engine ?? .webKit, agentOwnerID: owner.id)
        tabs.append(tab)
        load(url, in: tab.id)
        return tab
    }

    func navigate(_ tabID: UUID, _ navigation: AgentNavigation) {
        navigations.append(navigation)
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        switch navigation {
        case .load(let url): load(url, in: tabID)
        case .reload: if let url = tab.url { load(url, in: tabID, keepsHistory: true) }
        case .back:
            if let previous = backList[tabID]?.popLast() { load(previous, in: tabID, keepsHistory: true) }
        case .forward: break
        }
    }

    func closeAgentTab(_ tabID: UUID) {
        closedTabIDs.append(tabID)
        tabs.removeAll { $0.id == tabID }
    }

    func readableContent(of tabID: UUID, limit: Int, completion: @escaping (Result<EngineReadableContent, any Error>) -> Void) {
        guard !silentTabIDs.contains(tabID) else { return }
        guard let tab = tabs.first(where: { $0.id == tabID }), let url = tab.url else { return completion(.failure(EngineReadableContentError.unreadable)) }
        let text = pages[url]?.text ?? ""
        beforeReturningContent?()
        completion(.success(EngineReadableContent(url: url, title: tab.title, text: String(text.prefix(limit)), isTruncated: text.count > limit)))
    }

    func runPageScript(_ source: String, world: String, in tabID: UUID, completion: @escaping (Result<String?, any Error>) -> Void) {
        guard !silentTabIDs.contains(tabID) else { return }
        guard let contents = webContents[tabID] else { return completion(.failure(EngineReadableContentError.unreadable)) }
        contents.executeJavaScript(source, inWorld: world, completion: completion)
    }

    func capture(_ tabID: UUID, fullPage: Bool, completion: @escaping (NSImage?) -> Void) {
        onCapture?()
        guard !hangingCaptureTabIDs.contains(tabID) else { return }
        if let image = captures[tabID] { return completion(image) }
        guard let contents = webContents[tabID] else { return completion(nil) }
        if fullPage { contents.captureFullPage(completion: completion) } else { contents.captureViewport(completion: completion) }
    }

    func userTabs(in personaID: UUID) -> [AgentTabInfo] { tabs.filter { userTabIDs.contains($0.id) && $0.agentOwnerID == nil } }

    func showTab(_ tabID: UUID) { shownTabIDs.append(tabID) }

    func agentDownloads(of ownerID: UUID) -> [AgentDownloadInfo] { downloads[ownerID] ?? [] }

    func appName(forOpening url: URL) -> String? { url.scheme.flatMap { appNames[$0] } }

    func openExternally(_ url: URL) { openedExternally.append(url) }

    func showAgentPanel(for ownerID: UUID) { shownPanels.append(ownerID) }

    func searchHistory(_ query: String, limit: Int) async -> [AgentHistoryPage] {
        Array(history.filter { $0.url.absoluteString.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) }.prefix(limit))
    }

    /// Loads `url` on the next turn, as an engine answers: it asks before the address and each redirect hop, then commits the last one, which changes the tab's address, and reports the document once it finishes, or reports only the stop when a hop was refused or the load failed.
    func load(_ url: URL, in tabID: UUID, keepsHistory: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].isLoading = true
        let owner = tabs[index].agentOwnerID
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                var address = url
                while true {
                    if let owner, agentTabMayLoad?(owner, tabID, address) == false { return stop(tabID) }
                    guard let next = redirects[address] else { break }
                    address = next
                }
                guard !hangingAddresses.contains(address) else { return }
                guard !failingAddresses.contains(address) else { return stop(tabID) }
                guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
                if !keepsHistory, let current = tabs[index].url { backList[tabID, default: []].append(current) }
                tabs[index].url = address
                if let owner { agentTabDidReport?(owner, tabID, .addressChanged(address)) }
                guard !committingAddresses.contains(address) else { return }
                tabs[index].title = pages[address]?.title ?? ""
                tabs[index].isLoading = false
                tabs[index].canGoBack = !(backList[tabID] ?? []).isEmpty
                if let owner {
                    agentTabDidReport?(owner, tabID, .loaded(url: address, title: tabs[index].title))
                    agentTabDidReport?(owner, tabID, .stoppedLoading)
                }
            }
        }
    }

    private func stop(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].isLoading = false
        if let owner = tabs[index].agentOwnerID { agentTabDidReport?(owner, tabID, .stoppedLoading) }
    }

    /// A page in `openerID` opens a tab at `url`, which joins the opener's folder, as `Browsing` reports it.
    @discardableResult
    func openPopup(from openerID: UUID, at url: URL) -> UUID? {
        guard let opener = tabs.first(where: { $0.id == openerID }), let owner = opener.agentOwnerID else { return nil }
        let popup = AgentTabInfo(id: UUID(), spaceID: opener.spaceID, title: "", url: nil, isLoading: true, engine: opener.engine, agentOwnerID: owner)
        tabs.append(popup)
        guard agentTabMayLoad?(owner, openerID, url) != false else {
            tabs.removeAll { $0.id == popup.id }
            return nil
        }
        agentTabDidReport?(owner, openerID, .opened(tab: popup.id))
        load(url, in: popup.id)
        return popup.id
    }

    /// The user drags the tab out of its agent folder.
    func takeOver(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), let owner = tabs[index].agentOwnerID else { return }
        tabs[index].agentOwnerID = nil
        agentTabDidReport?(owner, tabID, .takenOver)
    }

    /// What `Browsing` reports from an agent tab.
    func report(_ report: AgentTabReport, in tabID: UUID) {
        guard let owner = tabs.first(where: { $0.id == tabID })?.agentOwnerID else { return }
        agentTabDidReport?(owner, tabID, report)
    }

    func makeAgentsPersona() -> UUID {
        madeAgentsPersonas += 1
        let persona = AgentPersonaInfo(id: UUID(), name: "Agents")
        personas.append(persona)
        spacesByPersona[persona.id] = [AgentSpaceInfo(id: UUID(), name: "Personal")]
        return persona.id
    }

    func setAgentOnlyPersona(_ id: UUID?) { agentOnlyPersonaID = id }

    func windowForSheet() -> NSWindow? { nil }

    func deletePersona(_ id: UUID) {
        personas.removeAll { $0.id == id }
        spacesByPersona[id] = nil
        personasDidChange?()
    }
}

/// A runner on a CLI that records what the session sends and emits the events a test gives it.
@MainActor final class FakeRunner: AgentCommandLineRunning {
    let request: AIAgentSessionRequest
    let events: AsyncThrowingStream<AIAgentEvent, any Error>
    private let continuation: AsyncThrowingStream<AIAgentEvent, any Error>.Continuation
    var processID: pid_t?
    var processDidStart: ((pid_t) -> Void)?
    private(set) var sent: [String] = []
    private(set) var stops = 0
    private(set) var endedKeepingThread: Bool?
    private(set) var activeToolCalls = 0
    private(set) var toolCalls = 0
    private(set) var reportedTools: [[String]] = []

    init(request: AIAgentSessionRequest) {
        self.request = request
        (events, continuation) = AsyncThrowingStream.makeStream()
    }

    /// The CLI process starts, as `posix_spawn` returns.
    func startProcess(_ processID: pid_t) {
        self.processID = processID
        processDidStart?(processID)
    }

    func emit(_ event: AIAgentEvent) {
        continuation.yield(event)
    }

    func fail(_ error: AIError) {
        continuation.finish(throwing: error)
    }

    /// As `AIAgentSession` does while Claude Code may hold a session with Arch's skills.
    func checkMessage(_ message: String) throws {
        if request.skills != nil, message.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") { throw AIError.blockedByPolicy(.agentMessageIsCommand) }
    }

    func send(_ message: String) throws {
        try checkMessage(message)
        sent.append(message)
    }

    func stop() { stops += 1 }

    /// How long `end` takes, as Codex's thread deletion can.
    var endDelay: Duration?

    func end(keepingThread: Bool) async {
        endedKeepingThread = keepingThread
        if let endDelay { try? await Task.sleep(for: endDelay) }
        processID = nil
        continuation.finish()
    }

    func toolCallDidStart() {
        activeToolCalls += 1
        toolCalls += 1
    }

    func toolCallDidEnd() { activeToolCalls -= 1 }

    func toolListDidChange(_ tools: [String]) { reportedTools.append(tools) }

    func endProcesses() { processID = nil }
}

/// Answers each sheet with the next of `answers`, or Don't Allow once they run out; while `holdsAnswers` is set, a sheet waits for `release()`, as one the user has not answered yet.
@MainActor final class FakePrompt: AgentGrantPrompting {
    var answers: [AgentGrantChoice?] = []
    var holdsAnswers = false
    private(set) var requests: [AgentGrantRequest] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    func ask(_ request: AgentGrantRequest) async -> AgentGrantChoice? {
        requests.append(request)
        if holdsAnswers { await withCheckedContinuation { held.append($0) } }
        return answers.isEmpty ? nil : answers.removeFirst()
    }

    /// Answers the sheets that wait.
    func release() {
        holdsAnswers = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    func cancelAll() {}
}

final class FakeAuthenticator: AgentAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var _answer = true
    private var _count = 0

    var answer: Bool {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    var count: Int { lock.withLock { _count } }

    func authenticate(reason: String) async -> Bool {
        lock.withLock {
            _count += 1
            return _answer
        }
    }
}

/// A seal key and its generation in memory; `failure` makes it act as a Keychain that does not give the key.
final class MemoryKeys: AgentSealKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentSealKey?
    private var _failure: String?

    init(key: SymmetricKey? = nil) {
        stored = key.map { AgentSealKey(key: $0) }
    }

    var failure: String? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    var key: SymmetricKey? { lock.withLock { stored?.key } }
    /// The generation of the last write recorded.
    var generation: Int? { lock.withLock { stored?.generation } }

    func key() async throws -> AgentSealKey? {
        try lock.withLock {
            if let failure = _failure { throw TestKeyError(message: failure) }
            return stored
        }
    }

    func keyCreatingIfNeeded() async throws -> AgentSealKey {
        try lock.withLock {
            if let failure = _failure { throw TestKeyError(message: failure) }
            if let stored { return stored }
            let key = AgentSealKey(key: SymmetricKey(size: .bits256))
            stored = key
            return key
        }
    }

    func record(_ key: AgentSealKey) async throws {
        try lock.withLock {
            if let failure = _failure { throw TestKeyError(message: failure) }
            stored = key
        }
    }
}

struct TestKeyError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The code directory hash of this test process's running code, which the service's check expects when the client is this process.
func ownCodeHash() throws -> Data {
    var code: SecCode?
    try #require(SecCodeCopySelf([], &code) == errSecSuccess)
    var information: CFDictionary?
    try #require(SecCodeCopySigningInformation(unsafeBitCast(code!, to: SecStaticCode.self), [], &information) == errSecSuccess)
    return try #require((information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
}

/// A mutable value that `@Sendable` closures can read, such as the identity a test hands the service.
final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@MainActor final class Harness {
    let folder: URL
    let location: AgentSocketLocation
    let host = FakeHost()
    let prompt = FakePrompt()
    let authenticator = FakeAuthenticator()
    let keys: MemoryKeys
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let identity = Shared(AgentClientIdentity(key: .signed(identifier: "com.example.agent", team: "ABCDE12345"), name: "agent", executablePath: "/Applications/Agent.app/Contents/MacOS/agent", host: "Agent", isInterpreter: false))
    let processStarts = Shared<[pid_t: AgentProcessStart]>([:])
    /// The process table the tickets' ancestry check reads.
    let processRecords = Shared<[pid_t: AgentProcessRecord]>([:])
    /// The runners the service started, in order, and the requests it started them with.
    private(set) var runners: [FakeRunner] = []
    private(set) var requests: [AIAgentSessionRequest] = []
    var sessionRoute: (AIModelRef?) throws -> AIAgentSessionRoute = { _ in .commandLine }
    var apiClient: any AIClient = ScriptedClient { _ in [] }
    var agentModels = [AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet"), AIModelRef(provider: AIProviderID(rawValue: "codex"), model: "gpt-6")]
    let excludedHosts = Shared<Set<String>>(["excluded.example"])
    /// How long the services' calls wait for the user before they answer `approvalPending`, when not the default.
    var answerWait: TimeInterval?
    var services: [AgentService] = []

    init(keys: MemoryKeys = MemoryKeys()) throws {
        // Short, so that the socket's path fits `sun_path`.
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        location = AgentSocketLocation(path: folder.appendingPathComponent("Agent/control.sock").path, isInTemporaryFolder: true)
        self.keys = keys
    }

    func cleanUp() {
        services.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: folder)
    }

    var settingsURL: URL { folder.appendingPathComponent("agent.json") }

    /// Checks that pass for this test process's own code, with `readPeer` in place of the kernel's report when given.
    func checks(expectedHash: Data?, readPeer: (@Sendable (Int32) throws -> AgentPeer)? = nil) -> AgentEndpoint.PeerChecks {
        let check = AgentPeerCheck(expectedHash: expectedHash)
        return AgentEndpoint.PeerChecks(read: readPeer ?? { try AgentPeer.read(socket: $0) }, verify: { try check.verify($0) })
    }

    func makeService(checks: AgentEndpoint.PeerChecks? = nil) throws -> AgentService {
        let identity = identity
        let starts = processStarts
        let records = processRecords
        let sessionsFolder = folder.appendingPathComponent("sessions", isDirectory: true)
        var dependencies = AgentService.Dependencies(
            location: location,
            keys: keys,
            peerChecks: try checks ?? self.checks(expectedHash: ownCodeHash()),
            identify: { _ in identity.value },
            processStart: { starts.value[$0] },
            prompt: prompt,
            authenticator: authenticator,
            allowsAI: { [excludedHosts] url in url.host.map { !excludedHosts.value.contains($0) } ?? false },
            // A report that arrives after the test, such as a refused peer's, reads the clock of a harness that is gone.
            now: { [weak self] in self?.now ?? Date() },
            processRecord: { records.value[$0] },
            startRunner: { [unowned self] request in
                let runner = FakeRunner(request: request)
                self.runners.append(runner)
                self.requests.append(request)
                return runner
            },
            sessionRoute: { [unowned self] in try self.sessionRoute($0) },
            apiClient: apiClient,
            mcpExecutable: URL(fileURLWithPath: "/Applications/Arch.app/Contents/Helpers/arch-mcp"),
            sessionFolder: { sessionsFolder.appendingPathComponent($0.uuidString, isDirectory: true) },
            agentModels: { [unowned self] in self.agentModels },
            subscriptionToolName: { ["codex": "Codex", "claude": "Claude Code"][$0.rawValue] })
        if let answerWait { dependencies.answerWait = answerWait }
        let service = AgentService(directory: folder, host: host, version: "9.9.9", dependencies: dependencies)
        services.append(service)
        return service
    }

    /// Makes `processID` a child of `parent`, which started at `start`, in the process table the ticket check reads.
    func addProcess(_ processID: pid_t, parent: pid_t, start: AgentProcessStart = AgentProcessStart(seconds: 1_000, microseconds: 0)) {
        processRecords.value[processID] = AgentProcessRecord(processID: processID, parentID: parent, start: start)
    }

    /// A service whose settings are read and whose outside access is on.
    func makeOpenService(checks: AgentEndpoint.PeerChecks? = nil) async throws -> AgentService {
        let service = try makeService(checks: checks)
        try await settled(service)
        try await service.setAllowsOutsideClients(true)
        return service
    }

    /// Waits until the service has checked `agent.json`.
    func settled(_ service: AgentService) async throws {
        try await waitUntil { service.state != .reading }
    }

    var socketExists: Bool {
        var status = stat()
        return lstat(location.path, &status) == 0
    }
}

/// Polls on the main actor, which lets the endpoint's reports in, for at most five seconds.
@MainActor func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("A condition did not come true within five seconds.")
}

/// A client that runs each blocking call on a thread of its own, so that the main actor stays free for the service.
final class TestClient: @unchecked Sendable {
    let connection: AgentControlConnection

    init(_ location: AgentSocketLocation, check: @escaping (Int32) throws -> AgentPeer = { try AgentPeer.read(socket: $0) }) throws {
        connection = try AgentControlConnection(location: location, check: check)
    }

    /// Says `hello` as `arch-cli`, or as `arch-mcp --session` when it presents a ticket, as only that client does.
    func hello(protocol version: Int = AgentControlProtocol.version, ticket: String? = nil, client: AgentControl.AgentClientKind? = nil) async throws -> AgentHelloAnswer {
        let kind = client ?? (ticket == nil ? .cli : .mcp)
        return try await Task.detached { try self.connection.hello(AgentHello(protocol: version, client: kind, version: "9.9.9", ticket: ticket), timeout: 5) }.value
    }

    func callTool(_ name: String, _ arguments: [String: AgentJSON] = [:], timeout: TimeInterval = 5) async throws -> AgentToolResult {
        try await Task.detached { try self.connection.callTool(AgentToolCall(name: name, arguments: arguments), timeout: timeout) }.value
    }

    func call(_ method: String, params: AgentJSON? = nil) async throws -> AgentJSON {
        try await Task.detached { try self.connection.call(method, params: params, timeout: 5) }.value
    }

    func receive() async throws -> AgentRPCMessage {
        try await Task.detached { try self.connection.receive(timeout: 5) }.value
    }
}
