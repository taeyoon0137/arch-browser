// The agents' service in the app (docs/agents.md, Local control channel; Outside clients: identity, grants, revocation; Sealed settings): it owns `agent.json`, the activity log, the grants, and the control endpoint, which listens only while Allow Outside Clients is on or an in-app session needs it. It answers `hello`, asks for a grant at a client's first tool call, runs calls through the tool host, and ends a grant's connections when the grant is revoked, released, or expires. Every decision about a call is made here and in the tool host, never in `arch-cli` or `arch-mcp`.
import AgentControl
import AI
import AppKit
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

    /// Set while an in-app session on a CLI needs the channel, which then listens with outside access off; plan task VII.17 sets it.
    var sessionsNeedChannel = false {
        didSet { updateListening() }
    }

    /// The service for the app: its files in `directory`, the socket where `AgentSocketLocation` puts it, the seal key in the Keychain, and the peer checks against the bundled `arch-cli`, whose hash it reads now.
    public convenience init(directory: URL, host: any AgentBrowserHost, version: String) {
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
            now: Date.init))
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
            // Outside access went off while a session keeps the channel; sessions bind their connections with plan task VII.17, so every connection now is an outside client's.
            for id in connections.keys { endpoint?.close(id) }
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
            if let id = settings.agentsPersonaID, host.personas.contains(where: { $0.id == id }) {
                personaID = id
            } else {
                // Recorded before its first profile starts, so that its profiles never take the remembered answers.
                personaID = host.makeAgentsPersona()
                settings.agentsPersonaID = personaID
                applyAgentOnlyPersona()
            }
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
            let grant = connection.identity.flatMap(grant(for:))
            let tools = grant.map { AgentToolHost.tools(for: $0.level, scopes: $0.scopes) } ?? AgentToolHost.toolsBeforeGrant
            reply(connection, requestID, Self.json(AgentToolList(tools: tools.map(\.name))))
        case (.ready, AgentControlMethod.toolsCall):
            call(params, on: connection, requestID: requestID)
        case (.ready, AgentControlMethod.grantShow):
            if let identity = connection.identity { reply(connection, requestID, Self.json(answer(for: identity))) }
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
        // In-app sessions bind tickets with plan task VII.17; until then no ticket names a session.
        guard hello.ticket == nil else {
            return refuse(connection, requestID, AgentRefusal(reason: .ticket, message: "No agent session in Arch has this ticket."))
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
    var identity: AgentClientIdentity?
    var runningCalls = 0

    init(id: UUID, peer: AgentPeer) {
        self.id = id
        self.peer = peer
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
