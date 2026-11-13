// The agents' service in the app (docs/agents.md, Local control channel; Outside clients: identity, grants, revocation; Sealed settings; In the browser): it owns `agent.json`, the activity log, the grants, the in-app sessions, and the control endpoint, which listens only while Allow Outside Clients is on or an in-app session needs it. It answers `hello`, binds a session's `arch-mcp` by its ticket, asks for a grant at an outside client's first tool call, runs calls through the tool host, starts sessions for the user and for clients with the Start Agent Tasks scope, and ends a grant's connections when the grant is revoked, released, or expires. Every decision about a call is made here and in the tool host, never in `arch-cli` or `arch-mcp`.
import AgentControl
import AI
import AppKit
import Combine
import Foundation

@MainActor public final class AgentService: ObservableObject {
    /// How `agent.json` read at launch.
    public enum SettingsState: Equatable, Sendable {
        /// The seal is being checked; outside access stays off meanwhile.
        case reading
        case ready
        /// The seal did not match or the file did not read, so Arch renamed it `agent.json.unreadable` and started with the defaults.
        case replacedUnreadable
        /// The Keychain did not give the seal's key, for this reason. The file stays as it was; outside access stays off and no grant is used.
        case keyUnavailable(String)
    }

    @Published public private(set) var settings = AgentSettings()
    @Published public private(set) var state: SettingsState
    /// Grants until Arch quits, which `agent.json` never keeps.
    @Published public private(set) var launchGrants: [AgentGrant] = []
    /// Why the control socket does not listen while it should, as when another Arch uses it.
    @Published public private(set) var channelProblem: String?
    /// Why the last change to `agent.json` was not written.
    @Published public private(set) var saveProblem: String?
    /// The grants whose clients are connected now.
    @Published public private(set) var connectedGrantIDs: Set<UUID> = []
    /// In-app sessions in the order they started, until the user deletes them or Arch quits.
    @Published public private(set) var sessions: [AgentSession] = []
    public let activity: AgentActivityLog
    public let host: any AgentBrowserHost
    /// Arch's version, which `hello`'s answer names.
    public let version: String

    /// The grants in force: those `agent.json` keeps, then those until quit.
    public var grants: [AgentGrant] { settings.grants + launchGrants }

    /// What the service reads and asks through, which tests replace.
    struct Dependencies {
        var location: AgentSocketLocation?
        var keys: any AgentSealKeyStore
        var peerChecks: AgentEndpoint.PeerChecks
        /// The client of a connection, from its peer's process ID; runs off the main thread.
        var identify: @Sendable (pid_t) throws -> AgentClientIdentity
        /// A process's start time while it runs, for grants bound to a process.
        var processStart: (pid_t) -> AgentProcessStart?
        var prompt: any AgentGrantPrompting
        var authenticator: any AgentAuthenticating
        var allowsAI: (URL) -> Bool
        var now: () -> Date
        /// A process's parent and start time, for the tickets' ancestry check.
        var processRecord: @Sendable (pid_t) -> AgentProcessRecord?
        /// Starts a session's runner on the user's CLI: `AIService.startAgentSession(_:)` in the app.
        var startRunner: @MainActor (AIAgentSessionRequest) throws -> any AgentSessionRunning
        /// The bundled `arch-mcp` that each session's CLI starts.
        var mcpExecutable: URL
        /// Where a session's CLI works: `$TMPDIR/Arch-Agent-<session UUID>/` in the app.
        var sessionFolder: (UUID) -> URL
        /// The models that can run a session, in the `agent` route's order first, and a provider's tool name for errors, such as "Claude Code".
        var agentModels: @MainActor () -> [AIModelRef]
        var toolName: @MainActor (AIProviderID) -> String?
    }

    /// Don't Allow remembers nothing, but the next call of the same client asks again only after this long, so that a looping client cannot flood the user.
    static let askInterval: TimeInterval = 60
    static let settingsFileName = "agent.json"
    static let activityFileName = "agent-activity.json"

    private let dependencies: Dependencies
    private let file: AgentSettingsFile
    private var endpoint: AgentEndpoint?
    private var connections: [UUID: ClientConnection] = [:]
    /// The Persona that `agent.json` names while its seal cannot be checked, which stays agent-only: an unverified ID only restricts a Persona, never widens one.
    private var unverifiedAgentsPersonaID: UUID?
    private var declinedAt: [AgentClientIdentity.Key: Date] = [:]
    /// The grant sheet each client waits on, so that its calls share one sheet.
    private var questions: [AgentClientIdentity.Key: Task<AgentGrant?, Never>] = [:]
    private var handles: [UUID: AgentGrantHandles] = [:]
    private var usedThisLaunch: Set<UUID> = []
    private var expiryTimer: Timer?
    /// How long a session's call waits for the model's first output, and while the user has taken the session over; tests shorten them.
    var sessionReadyWait = AgentSession.readyWait
    var sessionTakeOverWait = AgentSession.takeOverWait
    /// Republish each session's turn starting and ending, which the bottom bar's indicator reads, and its waiting for the user starting and ending, which the bar's space symbols read.
    private var sessionObservers: [UUID: AnyCancellable] = [:]

    /// Set while an in-app session on a CLI lives, which then keeps the channel listening with outside access off.
    var sessionsNeedChannel = false {
        didSet { if sessionsNeedChannel != oldValue { updateListening() } }
    }

    /// The service for the app: its files in `directory`, the socket where `AgentSocketLocation` puts it, the seal key in the Keychain, and the peer checks against the bundled `arch-cli`, whose hash it reads now.
    public convenience init(directory: URL, host: any AgentBrowserHost, version: String) {
        // Folders a session of an earlier run left, as after a crash, go before any session starts.
        AIAgentSession.removeLeftoverFolders()
        let toolHash = try? AgentCodeIdentity.uniqueHash(ofFileAt: AgentBundleLayout(bundleURL: Bundle.main.bundleURL).cliExecutableURL)
        let identifier = AgentClientIdentifier(inspector: AgentSystemProcessInspector(), archProcessID: getpid(), toolHash: toolHash, passedOverPaths: AgentClientIdentifier.systemPassedOverPaths())
        let check = AgentPeerCheck(expectedHash: toolHash)
        self.init(directory: directory, host: host, version: version, dependencies: Dependencies(
            location: AgentSocketLocation.current(),
            keys: AgentKeychainSealKey(),
            peerChecks: AgentEndpoint.PeerChecks(read: { try AgentPeer.read(socket: $0) }, verify: { try check.verify($0) }),
            identify: { try identifier.identify(peer: $0) },
            processStart: { AgentSystemProcessInspector().record(of: $0)?.start },
            prompt: AgentGrantSheetPresenter(host: host),
            authenticator: AgentDeviceOwnerAuthentication(),
            allowsAI: { AIService.shared.settings.allowsAI(on: $0) },
            now: Date.init,
            processRecord: { AgentSystemProcessInspector().record(of: $0) },
            startRunner: { try AIService.shared.startAgentSession($0) },
            mcpExecutable: AgentBundleLayout(bundleURL: Bundle.main.bundleURL).mcpExecutableURL,
            sessionFolder: AIAgentSession.folder(for:),
            agentModels: { AIService.shared.agentSessionModels() },
            toolName: { id in AIService.shared.settings.providers.first { $0.id == id }.map(\.agentToolName) }))
        AIService.shared.register(.agent)
    }

    init(directory: URL, host: any AgentBrowserHost, version: String, dependencies: Dependencies) {
        self.host = host
        self.version = version
        self.dependencies = dependencies
        file = AgentSettingsFile(fileURL: directory.appendingPathComponent(Self.settingsFileName), keys: dependencies.keys)
        activity = AgentActivityLog(fileURL: directory.appendingPathComponent(Self.activityFileName), now: dependencies.now)
        // Until the seal is checked, the Persona the file names stays agent-only, before any of its profiles starts.
        unverifiedAgentsPersonaID = file.unverifiedAgentsPersonaID()
        state = FileManager.default.fileExists(atPath: file.fileURL.path) ? .reading : .ready
        applyAgentOnlyPersona()
        host.personasDidChange = { [weak self] in self?.personasDidChange() }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireGrants() }
        }
        if state == .reading {
            Task { await readSettings() }
        }
    }

    // MARK: Settings

    /// The Agents Persona that `agent.json` in `directory` names, read without the key. The app hands it to the browser session when it creates it, so that the Persona is agent-only before any of its profiles starts, as one a restored favorite's tab starts; the service then keeps the session's choice in line with the checked seal. An unverified ID only restricts a Persona, never widens one.
    public static func recordedAgentsPersonaID(in directory: URL) -> UUID? {
        AgentSettingsFile.unverifiedAgentsPersonaID(at: directory.appendingPathComponent(settingsFileName))
    }

    /// Whether outside clients may connect now: Allow Outside Clients is on in settings whose seal matched.
    var acceptsOutsideClients: Bool {
        switch state {
        case .ready, .replacedUnreadable: return settings.allowsOutsideClients
        case .reading, .keyUnavailable: return false
        }
    }

    /// Whether Settings can change outside access and grants now.
    public var canChangeSettings: Bool {
        state == .ready || state == .replacedUnreadable
    }

    private func readSettings() async {
        switch await file.read() {
        case .none:
            state = .ready
            unverifiedAgentsPersonaID = nil
        case .verified(let read):
            settings = read
            state = .ready
            unverifiedAgentsPersonaID = nil
            dropEndedGrants()
        case .replaced:
            settings = AgentSettings()
            state = .replacedUnreadable
            unverifiedAgentsPersonaID = nil
        case .keyUnavailable(let reason, let personaID):
            settings = AgentSettings()
            state = .keyUnavailable(reason)
            unverifiedAgentsPersonaID = personaID
        }
        applyAgentOnlyPersona()
        updateListening()
    }

    /// Settings' Try Again after the Keychain did not give the key.
    public func retryReadingSettings() {
        guard case .keyUnavailable = state else { return }
        state = .reading
        Task { await readSettings() }
    }

    /// Settings' Allow Outside Clients. Writing needs the seal key, which the Keychain may first ask the user for; turning access off closes outside clients' connections and keeps their grants.
    public func setAllowsOutsideClients(_ isOn: Bool) async throws {
        guard canChangeSettings else { throw AgentSettingsFileError.noKey }
        try await file.prepareKey()
        var changed = settings
        changed.allowsOutsideClients = isOn
        let record = try file.write(changed)
        settings = changed
        saveProblem = nil
        watch(record)
        updateListening()
    }

    private func save() {
        guard canChangeSettings else { return }
        if file.hasKey { return write() }
        Task {
            do {
                try await file.prepareKey()
                write()
            } catch {
                saveProblem = error.localizedDescription
            }
        }
    }

    private func write() {
        do {
            let record = try file.write(settings)
            saveProblem = nil
            watch(record)
        } catch {
            saveProblem = error.localizedDescription
        }
    }

    /// Says so when the Keychain did not record a write's generation, which leaves the file before it opening until a later write's record.
    private func watch(_ record: Task<Void, any Error>) {
        Task {
            do {
                try await record.value
            } catch {
                saveProblem = "The Keychain did not record this change, so an earlier copy of agent.json would still open: \(error.localizedDescription)"
            }
        }
    }

    /// The Persona whose profiles get no remembered answers: the recorded Agents Persona, or while the seal cannot be checked, the one the file names. The session never makes the default Persona agent-only, since its profile follows the answers from launch.
    private var agentOnlyPersonaID: UUID? {
        settings.agentsPersonaID ?? unverifiedAgentsPersonaID
    }

    private func applyAgentOnlyPersona() {
        host.setAgentOnlyPersona(agentOnlyPersonaID)
    }

    // MARK: Listening

    /// Listens while outside clients may connect or a session needs the channel, and otherwise removes the socket, so that clients report that agent access is off.
    func updateListening() {
        let isNeeded = acceptsOutsideClients || sessionsNeedChannel
        if isNeeded, endpoint == nil {
            guard let location = dependencies.location else {
                channelProblem = "The home folder's path is too long for the agent socket, and so is the temporary folder's."
                return
            }
            let endpoint = AgentEndpoint(location: location, checks: dependencies.peerChecks)
            endpoint.delegate = self
            do {
                try endpoint.start()
                self.endpoint = endpoint
                channelProblem = nil
            } catch {
                channelProblem = (error as? AgentEndpointError)?.message ?? "\(error)"
            }
        } else if !isNeeded, let endpoint {
            endpoint.stop()
            self.endpoint = nil
            connections = [:]
            updateConnectedGrants()
        } else if isNeeded, !acceptsOutsideClients {
            // Outside access went off while a session keeps the channel: only the sessions' own connections stay.
            for connection in connections.values where connection.sessionID == nil { endpoint?.close(connection.id) }
            // A session an outside client started stops with its access.
            endClientSessions(of: nil, because: "Outside access was turned off in Arch.")
        }
    }

    /// Ends the sessions an outside client started, those of one grant or all of them, with their connections: a session never outlives the access that started it.
    private func endClientSessions(of grantID: UUID?, because reason: String) {
        for session in sessions where session.isFromOutsideClient && !session.hasEnded && (grantID == nil || session.grantID == grantID) {
            for connection in connections.values where connection.sessionID == session.id { endpoint?.close(connection.id) }
            Task {
                await session.end(keepingThread: settings.keepsCodexCopy, because: reason)
                updateSessionsChannel()
            }
        }
    }

    /// Settings' Try Again after the socket could not listen.
    public func retryChannel() {
        guard endpoint == nil else { return }
        updateListening()
    }

    /// At quit: closes the grant sheets as Don't Allow, writes the grants' last-use dates, and removes the socket. Grants exist only once the key is in, so a launch without one writes nothing, and no write waits for the Keychain past quit. The Keychain may not record this last write's generation before Arch exits; the file before it then still opens, and it differs only in those dates, since every other change writes at once.
    public func stop() {
        expiryTimer?.invalidate()
        dependencies.prompt.cancelAll()
        for session in sessions where !session.isCleanedUp { session.endProcessesAtQuit() }
        if canChangeSettings, file.hasKey, !settings.grants.isEmpty { write() }
        activity.saveNow()
        endpoint?.stop()
        endpoint = nil
        connections = [:]
    }

    /// Closes the grant sheets as Don't Allow, so that AppKit can quit.
    public func cancelQuestions() {
        dependencies.prompt.cancelAll()
    }

    // MARK: Grants

    /// The grant in force for a client: same identity, not expired, bound to no process that has ended, and its Persona still there, so that a grant ends at once rather than at the next expiry check.
    func grant(for identity: AgentClientIdentity) -> AgentGrant? {
        let personas = Set(host.personas.map(\.id))
        let now = dependencies.now()
        return grants.first { $0.client.key == identity.key && !$0.hasExpired(at: now) && !hasProcessEnded($0) && personas.contains($0.personaID) }
    }

    /// Settings' Revoke.
    public func revoke(_ grantID: UUID) {
        guard let grant = grants.first(where: { $0.id == grantID }) else { return }
        end(grant, as: .revoked, telling: "The user revoked this client's access in Arch.")
    }

    /// Settings' Revoke All.
    public func revokeAll() {
        for grant in grants { end(grant, as: .revoked, telling: "The user revoked this client's access in Arch.") }
    }

    /// Ends a grant: the client's connections get `revoked` and close, and its handles go.
    private func end(_ grant: AgentGrant, as event: AgentActivityEntry.Event, telling message: String, except connectionID: UUID? = nil) {
        let wasKept = settings.grants.contains { $0.id == grant.id }
        settings.grants.removeAll { $0.id == grant.id }
        launchGrants.removeAll { $0.id == grant.id }
        handles[grant.id] = nil
        if wasKept { save() }
        record(event, grant: grant)
        endClientSessions(of: grant.id, because: message)
        for connection in connections.values where connection.identity?.key == grant.client.key && connection.id != connectionID {
            endpoint?.send(.notification(method: AgentControlMethod.revokedNotification, params: ["message": .string(message)]), to: connection.id)
            endpoint?.close(connection.id)
        }
        updateConnectedGrants()
    }

    /// Ends grants whose time is up and grants bound to a process that has ended.
    func expireGrants() {
        let now = dependencies.now()
        for grant in grants where grant.hasExpired(at: now) || hasProcessEnded(grant) {
            end(grant, as: .expired, telling: "This client's access to Arch expired.")
        }
    }

    private func hasProcessEnded(_ grant: AgentGrant) -> Bool {
        guard case .process(_, _, let processID, let start) = grant.client.key else { return false }
        return dependencies.processStart(processID) != start
    }

    /// Grants from `agent.json` that ended while Arch was not running, or whose Persona is gone, go without a sheet.
    private func dropEndedGrants() {
        expireGrants()
        personasDidChange()
    }

    /// A deleted Persona takes its grants with it, and a deleted Agents Persona leaves none recorded.
    private func personasDidChange() {
        let personas = Set(host.personas.map(\.id))
        for grant in grants where !personas.contains(grant.personaID) {
            end(grant, as: .revoked, telling: "The Persona of this client's access was deleted.")
        }
        sessionsPlacesDidChange(personas: personas)
        if let id = settings.agentsPersonaID, !personas.contains(id) {
            settings.agentsPersonaID = nil
            save()
            applyAgentOnlyPersona()
        } else if let id = unverifiedAgentsPersonaID, !personas.contains(id) {
            unverifiedAgentsPersonaID = nil
            applyAgentOnlyPersona()
        }
    }

    /// The grant for a call from a client without one: the sheet, at most once a minute per client, then Touch ID where the choice needs it. Replies the error itself when there is none.
    private func grantForCall(from connection: ClientConnection, _ identity: AgentClientIdentity, requestID: AgentRPCID) async -> AgentGrant? {
        if let grant = grant(for: identity) { return grant }
        guard acceptsOutsideClients else {
            replyError(connection, requestID, Self.noGrantError("Outside access is off. Turn on Allow Outside Clients in Settings \u{25B8} AI \u{25B8} Agents."))
            return nil
        }
        if let declined = declinedAt[identity.key], dependencies.now().timeIntervalSince(declined) < Self.askInterval {
            replyError(connection, requestID, Self.noGrantError("You did not allow \(identity.displayName) to use Arch a moment ago. Arch asks again after a minute."))
            return nil
        }
        endpoint?.send(.notification(method: AgentControlMethod.progressNotification, params: ["call": requestID.json, "message": "Waiting for your answer in Arch\u{2026}"]), to: connection.id)
        let question: Task<AgentGrant?, Never>
        if let waiting = questions[identity.key] {
            question = waiting
        } else {
            question = Task {
                let grant = await self.askForGrant(identity)
                self.questions[identity.key] = nil
                return grant
            }
            questions[identity.key] = question
        }
        guard let grant = await question.value else {
            replyError(connection, requestID, Self.noGrantError("You did not allow \(identity.displayName) to use Arch."))
            return nil
        }
        return grant
    }

    private func askForGrant(_ identity: AgentClientIdentity) async -> AgentGrant? {
        let agentsID = settings.agentsPersonaID.flatMap { id in host.personas.contains { $0.id == id } ? id : nil }
        let personas = host.personas.filter { $0.id != agentsID }
        let request = AgentGrantRequest(client: identity, personas: personas, agentsSpaces: agentsID.map(host.spaces(in:)) ?? [],
                                        spacesByPersona: Dictionary(uniqueKeysWithValues: personas.map { ($0.id, host.spaces(in: $0.id)) }))
        guard let choice = await dependencies.prompt.ask(request) else {
            decline(identity)
            return nil
        }
        if choice.needsAuthentication {
            guard await dependencies.authenticator.authenticate(reason: "allow \(identity.displayName) to use Arch") else {
                decline(identity)
                return nil
            }
        }
        // Outside access, or the Persona chosen, may have gone while the sheet showed.
        guard acceptsOutsideClients, let grant = makeGrant(choice, for: identity) else { return nil }
        toolsDidChange(for: identity.key)
        return grant
    }

    /// Sends `tools/changed` to the client's connections after a grant: their list before it named every served tool, and the grant's level and scopes may leave some out.
    private func toolsDidChange(for key: AgentClientIdentity.Key) {
        for connection in connections.values where connection.stage == .ready && connection.identity?.key == key {
            endpoint?.send(.notification(method: AgentControlMethod.toolsChangedNotification, params: nil), to: connection.id)
        }
    }

    private func decline(_ identity: AgentClientIdentity) {
        declinedAt[identity.key] = dependencies.now()
        activity.record(AgentActivityEntry(date: dependencies.now(), event: .declined, clientName: identity.displayName))
    }

    private func makeGrant(_ choice: AgentGrantChoice, for identity: AgentClientIdentity) -> AgentGrant? {
        let personaID: UUID
        switch choice.persona {
        case .agents:
            // The grant's own write records it.
            personaID = agentsPersona(saving: false)
        case .existing(let id):
            guard host.personas.contains(where: { $0.id == id }) else { return nil }
            personaID = id
        }
        let spaces = host.spaces(in: personaID)
        guard let spaceID = spaces.first(where: { $0.id == choice.spaceID })?.id ?? spaces.first?.id else { return nil }
        let now = dependencies.now()
        let grant = AgentGrant(client: identity, personaID: personaID, spaceID: spaceID, level: choice.level, scopes: choice.scopes, expiry: choice.duration.expiry(from: now), grantedAt: now)
        if choice.duration == .untilQuit {
            launchGrants.append(grant)
        } else {
            settings.grants.append(grant)
        }
        save()
        record(.granted, grant: grant, decision: choice.needsAuthentication ? .approvedWithTouchID : .approved)
        return grant
    }

    /// The Agents Persona, made with one space on first use. Recorded before its first profile starts, so that its profiles never take the remembered answers.
    private func agentsPersona(saving: Bool) -> UUID {
        if let id = settings.agentsPersonaID, host.personas.contains(where: { $0.id == id }) { return id }
        let id = host.makeAgentsPersona()
        settings.agentsPersonaID = id
        if saving { save() }
        applyAgentOnlyPersona()
        return id
    }

    private func record(_ event: AgentActivityEntry.Event, grant: AgentGrant, decision: AgentActivityEntry.Decision? = nil) {
        activity.record(AgentActivityEntry(date: dependencies.now(), event: event, grantID: grant.id, clientName: grant.client.displayName, personaID: grant.personaID, decision: decision))
    }

    /// Marks the grant used now. `agent.json` gets the date with its next write, at quit at the latest.
    private func touch(_ grant: AgentGrant) {
        let now = dependencies.now()
        if let index = settings.grants.firstIndex(where: { $0.id == grant.id }) { settings.grants[index].lastUsedAt = now }
        if let index = launchGrants.firstIndex(where: { $0.id == grant.id }) { launchGrants[index].lastUsedAt = now }
    }

    private func updateConnectedGrants() {
        let keys = Set(connections.values.compactMap(\.identity?.key))
        connectedGrantIDs = Set(grants.filter { keys.contains($0.client.key) }.map(\.id))
    }

    static func noGrantError(_ message: String) -> AgentRPCError {
        AgentRPCError(code: AgentControlErrorCode.noGrant, message: message)
    }


    // MARK: Sessions

    /// What starts an in-app session.
    public struct SessionStart {
        /// The task in the user's words, the session's first message.
        public var task: String
        public var personaID: UUID
        public var spaceID: UUID
        /// Tabs shared with the session from the start, such as the selected tab; one on a site excluded from AI is left out.
        public var attachedTabIDs: [UUID]
        public var mode: AgentAccessLevel
        /// Nil uses the `agent` route, or the first preset model when the route has none (`AIService.startAgentSession(_:)`).
        public var model: AIModelRef?
        public var effort: String?
        /// The composer's Use the Agents Persona: the session goes to the Agents Persona's first space instead.
        public var usesAgentsPersona: Bool
        var origin = AgentSession.Origin.app

        public init(task: String, personaID: UUID, spaceID: UUID, attachedTabIDs: [UUID], mode: AgentAccessLevel, model: AIModelRef?, effort: String?, usesAgentsPersona: Bool = false) {
            self.task = task
            self.personaID = personaID
            self.spaceID = spaceID
            self.attachedTabIDs = attachedTabIDs
            self.mode = mode
            self.model = model
            self.effort = effort
            self.usesAgentsPersona = usesAgentsPersona
        }
    }

    public struct SessionError: LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public func session(withID id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    /// The models that can run a session, the `agent` route's first, for the composer's menu.
    public func agentModels() -> [AIModelRef] {
        dependencies.agentModels()
    }

    /// Starts a session on the user's CLI and sends its first message, which holds the task and the handles of the attached tabs. Throws a sentence when the space is gone or the Agents Persona cannot be recorded, and the runner's refusals, such as for a task that starts with `/`, which then stays in the composer.
    @discardableResult public func startSession(_ start: SessionStart) throws -> AgentSession {
        var personaID = start.personaID
        var spaceID = start.spaceID
        var attached = start.attachedTabIDs
        if start.usesAgentsPersona {
            guard canChangeSettings else { throw SessionError(message: "Arch cannot record the Agents Persona until it reads its agent settings.") }
            personaID = agentsPersona(saving: true)
            guard let first = host.spaces(in: personaID).first else { throw SessionError(message: "The Agents Persona has no space.") }
            spaceID = first.id
            // The selected tab belongs to another Persona, so the session reads it only once the user shares it.
            attached = []
        }
        guard host.spaces(in: personaID).contains(where: { $0.id == spaceID }) else { throw SessionError(message: "The session's space was deleted.") }
        var scope = AgentSiteScope(searchResults: host.searchResultsAddress)
        let tabs = host.tabs(withIDs: Set(attached)).filter { tab in tab.url.map { AgentSite.of($0) != nil && dependencies.allowsAI($0) } ?? false }
        tabs.compactMap(\.url).forEach { scope.add($0) }
        let session = AgentSession(title: AgentSession.title(forTask: start.task), personaID: personaID, spaceID: spaceID, origin: start.origin, mode: start.mode,
                                   model: start.model, effort: start.effort, scope: scope, attachedTabIDs: tabs.map(\.id), tools: [])
        session.reportedTools = listedTools(for: session)
        let runner = try makeRunner(for: session)
        do {
            try runner.checkMessage(start.task)
        } catch {
            Task { await runner.end(keepingThread: false) }
            throw error
        }
        session.attach(runner, processRecord: dependencies.processRecord)
        configure(session)
        sessions.append(session)
        sessionsNeedChannel = true
        try session.send(start.task)
        return session
    }

    /// The runner for a session: the bundled `arch-mcp` with `--session` and the ticket, the first `tools/list` answer, the static harness, and for Claude Code the session's skill folder.
    private func makeRunner(for session: AgentSession) throws -> any AgentSessionRunning {
        let folder = dependencies.sessionFolder(session.id)
        let skills = AgentSessionSkills.skills(inSessionFolder: folder)
        let server = AIAgentToolServer(executable: dependencies.mcpExecutable, arguments: ["--session"], environment: [AgentMCPServer.ticketVariable: session.ticket.text], tools: session.reportedTools)
        let request = AIAgentSessionRequest(model: session.requestedModel, instructions: AgentHarness.instructions, toolServer: server, id: session.id, folder: folder, effort: session.effort, skills: skills)
        let runner = try dependencies.startRunner(request)
        do {
            try AgentSessionSkills.write(skills)
        } catch {
            Task { await runner.end(keepingThread: false) }
            throw SessionError(message: "The session's skills could not be written: \(error.localizedDescription)")
        }
        return runner
    }

    private func configure(_ session: AgentSession) {
        session.modeDidChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.toolsDidChange(forSession: session.id)
        }
        session.describe = { [weak self] error in self?.describe(error) ?? (error.localizedDescription, .retry) }
        sessionObservers[session.id] = session.$isTurnRunning.combineLatest(session.$state.map { $0 == .waitingForUser })
            .removeDuplicates(by: ==)
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// One sentence and one action for an error in a session (docs/agents.md, Errors).
    private func describe(_ error: AIError) -> (String, AgentErrorAction?) {
        switch error {
        case .authentication(let provider):
            return ("\(dependencies.toolName(provider) ?? "The tool") is not signed in.", .signIn(provider))
        case .notConfigured, .budgetReached:
            return (error.localizedDescription, .openAISettings)
        case .blockedByPolicy(.agentMessageIsCommand):
            return (error.localizedDescription, nil)
        default:
            return (error.localizedDescription, .retry)
        }
    }

    /// Retry after a session failed before any model held it, as after a refused start check: a new runner, then the last message again. A conversation a model held has no Retry, since a new runner would not carry it.
    public func retry(_ session: AgentSession) async {
        guard case .failed = session.state, !session.hasEnded, session.model == nil, let old = session.runner else { return session.retryLastMessage() }
        await old.end(keepingThread: false)
        guard !session.hasEnded else { return }
        do {
            session.replaceRunner(try makeRunner(for: session), processRecord: dependencies.processRecord)
            session.retryLastMessage()
        } catch {
            session.noteError(error)
        }
    }

    /// Delete Session: its connections close, its CLI processes and folder go, and Codex's copy of its thread unless Keep Codex's Copy of Agent Conversations is on.
    public func deleteSession(_ id: UUID) async {
        guard let session = session(withID: id) else { return }
        sessions.removeAll { $0.id == id }
        sessionObservers[id] = nil
        for connection in connections.values where connection.sessionID == id { endpoint?.close(connection.id) }
        await session.end(keepingThread: settings.keepsCodexCopy)
        updateSessionsChannel()
    }

    /// Stop All Agents: every session's turn stops and its queued messages go, and every outside client is disconnected; the grants stay. Plan task VII.13 also denies the pending approvals.
    public func stopAllAgents() {
        for session in sessions where !session.hasEnded { session.stop() }
        for connection in connections.values where connection.sessionID == nil { endpoint?.close(connection.id) }
    }

    /// Whether any agent acts now: a session's turn runs or an outside client is connected, for the bottom bar's indicator.
    public var isAnyAgentActing: Bool {
        sessions.contains { $0.isTurnRunning } || !connectedGrantIDs.isEmpty
    }

    /// The spaces with a session that waits for the user, whose symbols in the bottom bar show a dot.
    public var spacesWaitingForUser: Set<UUID> {
        Set(sessions.filter { !$0.hasEnded && $0.state == .waitingForUser }.map(\.spaceID))
    }

    /// At quit, before the endpoint stops: every session ends, with its folder and Codex's thread, within `limit`; whatever is left ends its processes at `stop()`.
    public func endSessionsForQuit(within limit: Duration = .seconds(5)) async {
        let live = sessions.filter { !$0.hasEnded }
        guard !live.isEmpty else { return }
        let keepsCopy = settings.keepsCodexCopy
        // The first of the endings and the time limit returns; an ending that has not finished by then ends its processes at `stop()`.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once(continuation)
            let ending = Task { @MainActor in
                await withTaskGroup(of: Void.self) { group in
                    for session in live { group.addTask { await session.end(keepingThread: keepsCopy) } }
                }
                once.resume()
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume()
                ending.cancel()
            }
        }
    }

    /// A deleted Persona takes its sessions with it; a deleted space stops its sessions, which stay in the panel until deleted.
    private func sessionsPlacesDidChange(personas: Set<UUID>) {
        for session in sessions where !personas.contains(session.personaID) {
            Task { await deleteSession(session.id) }
        }
        for session in sessions where personas.contains(session.personaID) && !session.hasEnded && !host.spaces(in: session.personaID).contains(where: { $0.id == session.spaceID }) {
            for connection in connections.values where connection.sessionID == session.id { endpoint?.close(connection.id) }
            Task {
                await session.end(keepingThread: settings.keepsCodexCopy)
                updateSessionsChannel()
            }
        }
    }

    private func updateSessionsChannel() {
        sessionsNeedChannel = sessions.contains { !$0.hasEnded }
    }

    /// Where Use the Agents Persona starts a session, as "Persona / Space": the Agents Persona's first space, or the one Arch makes with it.
    public var agentsPersonaPlace: String {
        let id = settings.agentsPersonaID
        let persona = id.flatMap { id in host.personas.first { $0.id == id }?.name } ?? "Agents"
        let space = id.flatMap { host.spaces(in: $0).first?.name } ?? "Personal"
        return "\(persona) / \(space)"
    }

    /// "Persona / Space", as the interface names a session's place.
    public func place(of session: AgentSession) -> String {
        let persona = host.personas.first { $0.id == session.personaID }?.name ?? "Deleted Persona"
        guard let space = host.spaces(in: session.personaID).first(where: { $0.id == session.spaceID }) else { return persona }
        return "\(persona) / \(space.name)"
    }

    // MARK: Session settings

    public func setNewSessionMode(_ mode: AgentAccessLevel) {
        guard canChangeSettings else { return }
        settings.newSessionMode = mode
        save()
    }

    public func setInAppAgentsSearchHistory(_ isOn: Bool) {
        guard canChangeSettings else { return }
        settings.inAppAgentsSearchHistory = isOn
        save()
    }

    public func setKeepsCodexCopy(_ isOn: Bool) {
        guard canChangeSettings else { return }
        settings.keepsCodexCopy = isOn
        save()
    }

    // MARK: Session connections

    /// A ticket binds the connection to its session only when it matches one, compared with every session's in constant time, and the session's running CLI process is an ancestor of the peer by process ID and start time. A ticket used from outside that tree is refused, logged, and noted in the session.
    private func bind(_ connection: ClientConnection, _ requestID: AgentRPCID, hello: AgentHello, ticket: String) {
        var matched: AgentSession?
        for session in sessions where session.ticket.matches(ticket) && matched == nil { matched = session }
        // Only `arch-mcp --session` presents a ticket.
        guard hello.client == .mcp, let session = matched, !session.hasEnded, let process = session.liveProcess,
              AgentProcessAncestry.isProcess(connection.peer.processID, descendedFrom: process, records: dependencies.processRecord) else {
            if let session = matched, !session.hasEnded, hello.client == .mcp { session.noteForeignTicketUse() }
            activity.record(AgentActivityEntry(date: dependencies.now(), event: .refusedPeer, sessionID: matched?.id, clientName: hello.client.rawValue,
                                               outcome: matched == nil ? "the ticket names no session" : "the ticket's program is not the session's"))
            return refuse(connection, requestID, AgentRefusal(reason: .ticket, message: "No agent session in Arch has this ticket for this program."))
        }
        connection.hello = hello
        connection.sessionID = session.id
        connection.stage = .ready
        reply(connection, requestID, Self.json(AgentHelloAnswer(version: version, status: .bound)))
    }

    /// Whether a session may search history: Let In-App Agents Search History, and for a session an outside client started also its grant's Search History scope, which a revoked grant no longer has.
    private func searchesHistory(_ session: AgentSession) -> Bool {
        guard settings.inAppAgentsSearchHistory else { return false }
        guard let grantID = session.grantID else { return true }
        return grants.first { $0.id == grantID }?.scopes.searchHistory ?? false
    }

    private func listedTools(for session: AgentSession) -> [String] {
        AgentToolHost.tools(for: session.mode, scopes: AgentGrantScopes(searchHistory: searchesHistory(session), startTasks: false)).map(\.name)
    }

    /// `tools/list` on a session's connection: the tools its mode allows. A list that differs from the last one reported, as after a mode change, reaches the runner, whose start check accepts it in a later `init`.
    private func listTools(for session: AgentSession) -> [String] {
        let tools = listedTools(for: session)
        if tools != session.reportedTools {
            session.reportedTools = tools
            session.runner?.toolListDidChange(tools)
        }
        return tools
    }

    /// Sends `tools/changed` on the session's connections after its mode changed.
    private func toolsDidChange(forSession id: UUID) {
        for connection in connections.values where connection.stage == .ready && connection.sessionID == id {
            endpoint?.send(.notification(method: AgentControlMethod.toolsChangedNotification, params: nil), to: connection.id)
        }
    }

    /// A session's call: held until the model's first output for at most 10 seconds, then refused, so that no page data flows before the start check passed; held while the user has taken the session over; counted against the session's limits; run by the tool host; and shown as a step. The runner's idle timer pauses meanwhile.
    private func sessionCall(_ params: AgentJSON?, of session: AgentSession, on connection: ClientConnection, requestID: AgentRPCID) {
        guard connection.runningCalls < AgentLimits.callsPerConnection else {
            return replyError(connection, requestID, AgentRPCError(code: AgentControlErrorCode.busy, message: "This connection already runs \(AgentLimits.callsPerConnection) calls."))
        }
        guard let call = try? params?.decode(as: AgentToolCall.self) else {
            return replyError(connection, requestID, .invalidParams("tools/call needs a tool's name and its arguments."))
        }
        connection.runningCalls += 1
        let runner = session.runner
        let epoch = session.callEpoch
        runner?.toolCallDidStart()
        Task {
            defer {
                connection.runningCalls -= 1
                runner?.toolCallDidEnd()
            }
            let result = await sessionResult(of: call, in: session, arrivedAt: epoch, on: connection)
            guard connections[connection.id] != nil else { return }
            let tool = AgentToolCatalog.tool(named: call.name)
            let tabHandle = call.arguments["tab"]?.stringValue
            session.record(AgentStepText.step(for: call, result: result, tabHandle: tabHandle, tabID: tabHandle.flatMap(session.handles.tabs.id(for:))))
            activity.record(AgentActivityEntry(date: dependencies.now(), event: .toolCall, grantID: session.grantID, sessionID: session.id, clientName: session.clientName,
                                               personaID: session.personaID, tool: tool?.name, toolClass: tool?.toolClass.rawValue,
                                               decision: result.status == .refused ? .refused : .auto, rule: result.status == .refused ? result.code : nil, outcome: result.status.rawValue))
            reply(connection, requestID, Self.json(result))
        }
    }

    private func sessionResult(of call: AgentToolCall, in session: AgentSession, arrivedAt epoch: Int, on connection: ClientConnection) async -> AgentToolResult {
        guard await session.ready.wait(timeout: sessionReadyWait) else {
            if let stale = session.staleCallResult(arrivedAt: epoch) { return stale }
            return AgentToolResult(status: .refused, code: "notReady", text: "Arch did not see the session's tool start as it asked, so it runs none of this session's tool calls.")
        }
        // A call the turn's end or Stop cut off, or whose connection closed while it waited, runs nothing.
        if let stale = session.staleCallResult(arrivedAt: epoch) { return stale }
        guard await session.handedBack.wait(timeout: sessionTakeOverWait) else {
            if let stale = session.staleCallResult(arrivedAt: epoch) { return stale }
            return AgentToolResult(status: .timeout, text: session.hasEnded ? "The session ended." : "The user took the session over and has not handed it back. Wait for the user's next message.")
        }
        if let stale = session.staleCallResult(arrivedAt: epoch) { return stale }
        guard connections[connection.id] != nil else { return AgentToolResult(status: .refused, code: "stopped", text: "The connection closed, so Arch did not run this call.") }
        if let refusal = session.countCall() { return refusal }
        var handles = session.handles
        let result = AgentToolHost(host: host, allowsAI: dependencies.allowsAI).run(call, for: AgentToolClient(session: session, searchesHistory: searchesHistory(session)), handles: &handles)
        session.handles = handles
        return result
    }

    private func closeConnection(_ connection: ClientConnection) {
        endpoint?.close(connection.id)
    }

    // MARK: Tasks from outside clients

    /// `task/start`: a session for an outside client whose grant has the Start Agent Tasks scope, as `AgentTaskPlan` resolves it: in the grant's Persona and the space it names among that Persona's spaces, at most at the lower of the grant's level and the Settings default. A client without a grant is asked for one first, as at its first tool call. The client's text adds nothing to the site scope, and the session's `task/event` notifications go to this connection.
    private func startTask(_ params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard let identity = connection.identity else { return }
        connection.runningCalls += 1
        Task {
            defer { connection.runningCalls -= 1 }
            guard let grant = await grantForCall(from: connection, identity, requestID: requestID), connections[connection.id] != nil else { return }
            startTask(params, for: grant, identity: identity, on: connection, requestID: requestID)
        }
    }

    private func startTask(_ params: AgentJSON?, for grant: AgentGrant, identity: AgentClientIdentity, on connection: ClientConnection, requestID: AgentRPCID) {
        guard grant.scopes.startTasks else {
            return replyError(connection, requestID, Self.noGrantError("This client's grant does not include Start Agent Tasks. Revoke it in Settings \u{25B8} AI \u{25B8} Agents and allow it again with that scope."))
        }
        guard let start = try? params?.decode(as: AgentTaskStart.self), !start.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return replyError(connection, requestID, .invalidParams("task/start needs the task's text."))
        }
        let plan: AgentTaskPlan
        do {
            plan = try AgentTaskPlan.make(for: start, grant: grant, spaces: host.spaces(in: grant.personaID), models: dependencies.agentModels(), settingsDefault: settings.newSessionMode)
        } catch {
            return replyError(connection, requestID, .invalidParams((error as? AgentTaskPlan.Refusal)?.message ?? "\(error)"))
        }
        var session = SessionStart(task: start.task, personaID: grant.personaID, spaceID: plan.spaceID, attachedTabIDs: [], mode: plan.mode, model: plan.model, effort: nil)
        session.origin = .outsideClient(grantID: grant.id, clientName: identity.displayName, deniesApprovals: start.deniesApprovals)
        do {
            let started = try startSession(session)
            // Only the IDs, so that the closure does not keep the session and its transcript alive.
            let sessionID = started.id
            let connectionID = connection.id
            started.taskEvent = { [weak self] kind, text in
                self?.endpoint?.send(.notification(method: AgentControlMethod.taskEventNotification, params: Self.json(AgentTaskEvent(session: sessionID, kind: kind, text: text))), to: connectionID)
            }
            reply(connection, requestID, Self.json(summary(of: started)))
        } catch {
            replyError(connection, requestID, .invalidParams(error.localizedDescription))
        }
    }

    private func clientSessions(of connection: ClientConnection) -> [AgentSession]? {
        guard let identity = connection.identity, let grant = grant(for: identity) else { return nil }
        return sessions.filter { $0.grantID == grant.id }
    }

    private func listSessions(_ params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard var mine = clientSessions(of: connection) else { return replyError(connection, requestID, Self.noGrantError("This client has no grant.")) }
        if let reference = try? params?.decode(as: AgentSessionReference.self) {
            mine = mine.filter { $0.id == reference.session }
            guard !mine.isEmpty else { return replyError(connection, requestID, .invalidParams("This client started no session with that ID.")) }
        }
        reply(connection, requestID, Self.json(AgentSessionList(sessions: mine.map(summary(of:)))))
    }

    private func stopTask(_ params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard let mine = clientSessions(of: connection) else { return replyError(connection, requestID, Self.noGrantError("This client has no grant.")) }
        guard let reference = try? params?.decode(as: AgentSessionReference.self), let session = mine.first(where: { $0.id == reference.session }) else {
            return replyError(connection, requestID, .invalidParams("This client started no session with that ID."))
        }
        let wasRunning = session.isTurnRunning
        session.stop()
        reply(connection, requestID, ["stopped": .bool(wasRunning)])
    }

    func summary(of session: AgentSession) -> AgentSessionSummary {
        AgentSessionSummary(id: session.id, title: session.title, state: session.state.name, mode: session.mode, place: place(of: session),
                            model: session.model.map { "\(dependencies.toolName($0.provider) ?? $0.provider.rawValue) \u{2014} \(aiModelTitle($0.model))" })
    }

    // MARK: Messages

    private func handle(_ message: AgentRPCMessage, on connection: ClientConnection) {
        // Arch acts on clients' `tools/cancel` from plan task VII.13 on, and asks clients nothing.
        guard case .request(let requestID, let method, let params) = message else { return }
        switch (connection.stage, method) {
        case (.new, AgentControlProtocol.helloMethod):
            connection.stage = .greeting
            Task { await greet(connection, requestID, params) }
        case (.new, _), (.greeting, _):
            replyError(connection, requestID, .invalidRequest("Say hello first, once."))
            endpoint?.close(connection.id)
        case (.ready, AgentControlProtocol.helloMethod):
            replyError(connection, requestID, .invalidRequest("hello comes once per connection."))
        case (.ready, AgentControlMethod.toolsList):
            if let sessionID = connection.sessionID {
                guard let session = session(withID: sessionID) else { return closeConnection(connection) }
                return reply(connection, requestID, Self.json(AgentToolList(tools: listTools(for: session))))
            }
            let grant = connection.identity.flatMap(grant(for:))
            let tools = grant.map { AgentToolHost.tools(for: $0.level, scopes: $0.scopes) } ?? AgentToolHost.toolsBeforeGrant
            reply(connection, requestID, Self.json(AgentToolList(tools: tools.map(\.name))))
        case (.ready, AgentControlMethod.toolsCall):
            if let sessionID = connection.sessionID {
                guard let session = session(withID: sessionID) else { return closeConnection(connection) }
                return sessionCall(params, of: session, on: connection, requestID: requestID)
            }
            call(params, on: connection, requestID: requestID)
        case (.ready, AgentControlMethod.taskStart) where connection.sessionID == nil:
            startTask(params, on: connection, requestID: requestID)
        case (.ready, AgentControlMethod.taskStop) where connection.sessionID == nil:
            stopTask(params, on: connection, requestID: requestID)
        case (.ready, AgentControlMethod.sessionsList) where connection.sessionID == nil:
            listSessions(params, on: connection, requestID: requestID)
        case (.ready, AgentControlMethod.grantShow):
            // A session's connection is bound; it has no grant to show.
            let answer = connection.identity.map(answer(for:)) ?? AgentHelloAnswer(version: version, status: .bound)
            reply(connection, requestID, Self.json(answer))
        case (.ready, AgentControlMethod.grantRelease):
            guard let identity = connection.identity, let grant = grant(for: identity) else { return reply(connection, requestID, ["released": false]) }
            end(grant, as: .released, telling: "This client gave up its access to Arch.", except: connection.id)
            reply(connection, requestID, ["released": true])
        default:
            replyError(connection, requestID, .methodNotFound(method))
        }
    }

    /// Answers `hello`: another protocol version, a ticket that binds no session, and outside access off are refused and the connection closes; otherwise the client learns its grant, or that its first call asks for one.
    private func greet(_ connection: ClientConnection, _ requestID: AgentRPCID, _ params: AgentJSON?) async {
        guard let hello = try? params?.decode(as: AgentHello.self) else {
            replyError(connection, requestID, .invalidParams("hello needs protocol, client, and version."))
            endpoint?.close(connection.id)
            return
        }
        guard hello.protocol == AgentControlProtocol.version else {
            return refuse(connection, requestID, AgentRefusal(reason: .protocolMismatch, message: "Arch speaks version \(AgentControlProtocol.version) of the control protocol, and this client version \(hello.protocol)."))
        }
        if let ticket = hello.ticket {
            return bind(connection, requestID, hello: hello, ticket: ticket)
        }
        guard acceptsOutsideClients else {
            return refuse(connection, requestID, AgentRefusal(reason: .outsideAccessOff, message: "Outside access is off. Turn on Allow Outside Clients in Settings \u{25B8} AI \u{25B8} Agents."))
        }
        let identify = dependencies.identify
        let processID = connection.peer.processID
        let identity: AgentClientIdentity
        do {
            identity = try await Task.detached { try identify(processID) }.value
        } catch {
            return refuse(connection, requestID, AgentRefusal(reason: .unidentified, message: "Arch could not tell which program this is."))
        }
        guard connections[connection.id] != nil else { return }
        connection.hello = hello
        connection.identity = identity
        connection.stage = .ready
        updateConnectedGrants()
        reply(connection, requestID, Self.json(answer(for: identity)))
    }

    private func answer(for identity: AgentClientIdentity) -> AgentHelloAnswer {
        guard let grant = grant(for: identity) else { return AgentHelloAnswer(version: version, status: .noGrant) }
        let persona = host.personas.first { $0.id == grant.personaID }?.name ?? ""
        return AgentHelloAnswer(version: version, status: .granted(AgentGrantSummary(level: grant.level, persona: persona, expiry: grant.expiry)))
    }

    private func call(_ params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard let identity = connection.identity else { return }
        guard connection.runningCalls < AgentLimits.callsPerConnection else {
            return replyError(connection, requestID, AgentRPCError(code: AgentControlErrorCode.busy, message: "This connection already runs \(AgentLimits.callsPerConnection) calls."))
        }
        guard let call = try? params?.decode(as: AgentToolCall.self) else {
            return replyError(connection, requestID, .invalidParams("tools/call needs a tool's name and its arguments."))
        }
        connection.runningCalls += 1
        Task {
            defer { connection.runningCalls -= 1 }
            guard let grant = await grantForCall(from: connection, identity, requestID: requestID), connections[connection.id] != nil else { return }
            updateConnectedGrants()
            var grantHandles = handles[grant.id] ?? AgentGrantHandles()
            let result = AgentToolHost(host: host, allowsAI: dependencies.allowsAI).run(call, for: grant, handles: &grantHandles)
            handles[grant.id] = grantHandles
            if usedThisLaunch.insert(grant.id).inserted { record(.firstUse, grant: grant) }
            touch(grant)
            let tool = AgentToolCatalog.tool(named: call.name)
            activity.record(AgentActivityEntry(date: dependencies.now(), event: .toolCall, grantID: grant.id, clientName: identity.displayName, personaID: grant.personaID,
                                               tool: tool?.name, toolClass: tool?.toolClass.rawValue, decision: .auto, outcome: result.status.rawValue))
            reply(connection, requestID, Self.json(result))
        }
    }

    private func reply(_ connection: ClientConnection, _ requestID: AgentRPCID, _ result: AgentJSON) {
        endpoint?.send(.result(id: requestID, result: result), to: connection.id)
    }

    private func replyError(_ connection: ClientConnection, _ requestID: AgentRPCID, _ error: AgentRPCError) {
        endpoint?.send(.error(id: requestID, error: error), to: connection.id)
    }

    /// Answers `hello` with a refusal and closes the connection after it.
    private func refuse(_ connection: ClientConnection, _ requestID: AgentRPCID, _ refusal: AgentRefusal) {
        reply(connection, requestID, Self.json(AgentHelloAnswer(version: version, status: .refused(refusal))))
        endpoint?.close(connection.id)
    }

    static func json<Value: Encodable>(_ value: Value) -> AgentJSON {
        (try? AgentJSON(encoding: value)) ?? .null
    }
}

/// Resumes a continuation once, whichever of two tasks comes first.
@MainActor private final class Once {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// One accepted connection as the service sees it.
private final class ClientConnection {
    enum Stage {
        case new
        /// `hello` arrived and Arch is answering it.
        case greeting
        case ready
    }

    let id: UUID
    let peer: AgentPeer
    var stage = Stage.new
    var hello: AgentHello?
    /// An outside client's identity; nil for a session's connection.
    var identity: AgentClientIdentity?
    /// The in-app session whose ticket the connection presented.
    var sessionID: UUID?
    var runningCalls = 0

    init(id: UUID, peer: AgentPeer) {
        self.id = id
        self.peer = peer
    }
}

extension AIFeature {
    /// Agent Tasks (docs/agents.md, Model choice and fallbacks): sessions the user starts, whose page data reaches the model only as tool results that Arch checks. Its route lists only models that can run a session.
    public static let agent = AIFeature(id: .agent, name: "Agent Tasks",
                                        summary: "Runs agent sessions on Claude Code or Codex, which read and act in background tabs while Arch asks you before sensitive steps.",
                                        trigger: .user, data: AIDataScope(kinds: [.page, .selection, .file]), requirements: [.agent])
}

extension AIProviderConfiguration {
    /// "Claude Code" or "Codex" for a preset, otherwise the provider's name.
    var agentToolName: String {
        if case .commandLine(let tool) = kind, let agent = tool.agent { return agent.title }
        return name
    }
}

extension AgentService: AgentEndpointDelegate {
    func endpoint(_ endpoint: AgentEndpoint, didAccept connection: UUID, peer: AgentPeer) {
        guard endpoint === self.endpoint else { return }
        connections[connection] = ClientConnection(id: connection, peer: peer)
    }

    func endpoint(_ endpoint: AgentEndpoint, connection id: UUID, didReceive message: AgentRPCMessage) {
        guard endpoint === self.endpoint, let connection = connections[id] else { return }
        handle(message, on: connection)
    }

    func endpoint(_ endpoint: AgentEndpoint, didClose connection: UUID) {
        guard endpoint === self.endpoint else { return }
        connections[connection] = nil
        updateConnectedGrants()
    }

    func endpoint(_ endpoint: AgentEndpoint, didRefusePeer name: String, reason: String) {
        activity.record(AgentActivityEntry(date: dependencies.now(), event: .refusedPeer, clientName: name, outcome: reason))
    }
}
