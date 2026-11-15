// The agents' service in the app (docs/agents.md, Local control channel; Outside clients: identity, grants, revocation; Sealed settings; In the browser; Approval interface): it owns `agent.json`, the activity log, the grants, the in-app sessions, the cards that wait for the user, the agent panel's model, and the control endpoint, which listens only while Allow Outside Clients is on or an in-app session needs it. It answers `hello`, binds a session's `arch-mcp` by its ticket, asks for a grant at an outside client's first tool call, runs calls through the tool host, starts sessions for the user and for clients with the Start Agent Tasks scope, and ends a grant's connections when the grant is revoked, released, or expires. A revocation, expiry, Stop All Agents, a client's Stop, the client leaving, and quit end the cards they concern as denied, and all but quit cancel the outside clients' calls they concern that still run. A call that answers `approvalPending` records its entry and step when it ends. Every decision about a call is made here and in the tool host, never in `arch-cli` or `arch-mcp`.
import AgentControl
import AI
import AppKit
import Combine
import Events
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
    private var hookCLIs: [UUID: AgentHookCLIRun] = [:]
    /// Shell hook runs by their run's ID, whose `arch-cli` presents `ARCH_HOOK_TICKET` (`docs/hooks.md`, Shell scripts).
    private var shellHookRuns: [UUID: ShellHookRunAccess] = [:]
    /// Outside programs' event buffers and subscriptions (`docs/hooks.md`, Outside programs).
    let outsidePrograms = AgentOutsidePrograms()
    /// The hook registry, for hooks that outside programs propose; the app shell sets it once both exist.
    public weak var hookRegistrar: (any AgentHookRegistrar)? {
        didSet { grantsInForceDidChange() }
    }
    private var runObserver: AnyCancellable?
    /// The agent runner, made at first use; tests give their own, over a scripted model.
    var runService: AgentRunner?
    public var runs: AgentRunner {
        if let runService { return runService }
        let runner = AgentRunner(host: host, ai: .shared, activity: activity)
        runObserver = runner.$isRunning.dropFirst().removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() }
        runner.startCLI = { [weak self] binding, feature, models, turns, instructions in
            guard let self else { throw AIError.cancelled }
            return try self.startHookCLI(binding, feature: feature, models: models, turns: turns, instructions: instructions)
        }
        runner.finishCLI = { [weak self] in self?.finishHookCLI($0) }
        runService = runner
        return runner
    }
    public let host: any AgentBrowserHost
    /// The cards that wait for the user, and the agent panel that shows them with each client's steps.
    public let approvals = AgentApprovals()
    public let panel: AgentPanelModel
    /// Arch's version, which `hello`'s answer names.
    public let version: String

    /// The grants in force: those `agent.json` keeps, then those until quit.
    public var grants: [AgentGrant] { settings.grants + launchGrants }

    /// Connected programs in the same order as their grants, shown in the sidebar and the agents menu.
    public var connectedGrants: [AgentGrant] { grants.filter { connectedGrantIDs.contains($0.id) } }

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
        var startRunner: @MainActor (AIAgentSessionRequest) throws -> any AgentCommandLineRunning
        var sessionRoute: @MainActor (AIModelRef?) throws -> AIAgentSessionRoute
        var apiClient: any AIClient
        /// The bundled `arch-mcp` that each session's CLI starts.
        var mcpExecutable: URL
        /// Where a session's CLI works: `$TMPDIR/Arch-Agent-<session UUID>/` in the app.
        var sessionFolder: (UUID) -> URL
        /// The models that can run a session, in the `agent` route's order first, and a provider's tool name for errors, such as "Claude Code".
        var agentModels: @MainActor () -> [AIModelRef]
        var subscriptionToolName: @MainActor (AIProviderID) -> String?
        var providerMessage: @MainActor (AIError) -> String = { $0.localizedDescription }
        /// How long a call waits for the user before it answers `approvalPending`, and how long an outside client's card stays open.
        var answerWait = TimeInterval(AgentLimits.callAnswerSeconds)
        var approvalWindow = TimeInterval(AgentLimits.outsideApprovalDefaultMinutes * 60)
        /// Called when a card opens, for the notification without content while Arch is in the background.
        var attention: (UUID) -> Void = AgentAttention.notify
        var withdrawAttention: (UUID) -> Void = AgentAttention.withdraw
    }

    /// Don't Allow remembers nothing, but Arch shows one grant sheet at a time and no new one for this long after any Don't Allow or timeout, so that a looping client, even one that changes its identity, cannot flood the user.
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
    /// The last Don't Allow or timeout of any client, after which no new sheet opens for a minute.
    private var lastDeclinedAt: Date?
    /// The grant sheet each client waits on, so that its calls share one sheet.
    private var questions: [AgentClientIdentity.Key: Task<AgentGrant?, Never>] = [:]
    /// What the tool host keeps for each grant in force since its first call this launch.
    private var states: [UUID: AgentGrantState] = [:]
    private var usedThisLaunch: Set<UUID> = []
    private var expiryTimer: Timer?
    /// The write that Settings' agent runs a day waits to make.
    private var runsPerDaySave: Task<Void, Never>?
    /// How long a session's call waits for the model's first output, and while the user has taken the session over; tests shorten them.
    var sessionReadyWait = AgentSession.readyWait
    var sessionTakeOverWait = AgentSession.takeOverWait
    var sessionQuestionWindow = TimeInterval(AgentLimits.inAppApprovalMinutes * 60)
    /// Republish each session's turn starting and ending, which the bottom bar's indicator reads, and its waiting for the user starting and ending, which the bar's space symbols read.
    private var sessionObservers: [UUID: AnyCancellable] = [:]
    private var restartingSessions: Set<UUID> = []

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
            sessionRoute: AIService.shared.agentSessionRoute(for:),
            apiClient: AIService.shared,
            mcpExecutable: AgentBundleLayout(bundleURL: Bundle.main.bundleURL).mcpExecutableURL,
            sessionFolder: AIAgentSession.folder(for:),
            agentModels: { AIService.shared.agentSessionModels() },
            subscriptionToolName: { id in AIService.shared.settings.providers.first { $0.id == id }.flatMap { $0.commandLineAgent?.title } },
            providerMessage: { AIService.shared.settings.message(for: $0) }))
        AIService.shared.register(.agent)
        AIService.shared.register(.agentRun)
    }

    init(directory: URL, host: any AgentBrowserHost, version: String, dependencies: Dependencies) {
        self.host = host
        self.version = version
        self.dependencies = dependencies
        panel = AgentPanelModel(approvals: approvals)
        file = AgentSettingsFile(fileURL: directory.appendingPathComponent(Self.settingsFileName), keys: dependencies.keys)
        activity = AgentActivityLog(fileURL: directory.appendingPathComponent(Self.activityFileName), now: dependencies.now)
        // Until the seal is checked, the Persona the file names stays agent-only, before any of its profiles starts.
        unverifiedAgentsPersonaID = file.unverifiedAgentsPersonaID()
        state = FileManager.default.fileExists(atPath: file.fileURL.path) ? .reading : .ready
        applyAgentOnlyPersona()
        host.personasDidChange = { [weak self] in self?.personasDidChange() }
        host.userDocumentDidEnd = { [weak self] tabID, documentID in
            guard let self else { return }
            for card in self.approvals.pending where card.tabID == tabID && card.documentID == documentID {
                self.approvals.withdraw(card.id)
            }
            for session in self.sessions where session.handles.sharedTabIDs.contains(tabID) {
                session.objectWillChange.send()
            }
        }
        host.userTabAddressDidChange = { [weak self] tabID in
            guard let self else { return }
            for session in self.sessions where session.origin == .app && !session.hasEnded && session.handles.sharedTabIDs.contains(tabID) {
                session.objectWillChange.send()
            }
        }
        host.agentTabDidReport = { [weak self] owner, tab, report in self?.agentTab(tab, of: owner, didReport: report) }
        host.agentTabMayLoad = { [weak self] owner, tab, url, kind in self?.agentTab(tab, of: owner, mayLoad: url, kind: kind) ?? false }
        host.agentTabMayDownload = { [weak self] owner, tab, url in self?.toolHost().tab(tab, mayDownload: url, state: self?.toolState(of: owner)) ?? false }
        host.agentTabChoosesFiles = { [weak self] owner, tab, chooser in
            guard let self else { return chooser.deny() }
            self.agentTab(tab, of: owner, choosesFiles: chooser)
        }
        approvals.authenticator = dependencies.authenticator
        approvals.didAdd = { [weak self] approval in self?.cardDidOpen(approval) }
        approvals.didEnd = { [weak self] ownerID in
            // A session waits for the user while one of its cards waits, also a card a page in its agent tab opened.
            self?.session(withID: ownerID)?.setWaitingForAnswer(false)
            self?.dependencies.withdrawAttention(ownerID)
        }
        panel.showTab = { [weak host] in host?.showTab($0) }
        panel.stop = { [weak self] in self?.stopClient($0) }
        host.agentPanel = panel
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

    /// The highest mode a new session starts in: Settings' mode, or Read Only while the seal is not checked, since the defaults then stand in for the user's choice and must not raise it.
    public var newSessionMode: AgentAccessLevel {
        canChangeSettings ? settings.newSessionMode : .readOnly
    }

    /// Whether a session's end keeps Codex's copy of its thread: Keep Codex's Copy of Agent Conversations, and always while the seal is not checked, since the setting is not known then and a deleted thread does not come back.
    public var keepsCodexCopy: Bool {
        settings.keepsCodexCopy || !canChangeSettings
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
        grantsInForceDidChange()
    }

    /// Settings' Try Again after the Keychain did not give the key.
    public func retryReadingSettings() {
        guard case .keyUnavailable = state else { return }
        state = .reading
        Task { await readSettings() }
    }

    /// Settings' Allow Outside Clients. Writing needs the seal key, which the Keychain may first ask the user for; turning access off closes outside clients' connections and keeps their grants.
    public func setAllowsOutsideClients(_ isOn: Bool) async throws {
        guard canChangeSettings else { throw SealedSettingsFileError.noKey }
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
        // A grant sheet open when outside access goes off closes without a decline.
        if !acceptsOutsideClients { dependencies.prompt.cancelAll() }
        let isNeeded = acceptsOutsideClients || sessionsNeedChannel || !hookCLIs.isEmpty || !shellHookRuns.isEmpty
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
            // The endpoint reports no close once it stops, so its connections' calls and cards end here.
            for (id, connection) in connections {
                dropConnection(id, because: connection.identity == nil ? Self.clientLeft : "Outside access was turned off in Arch.")
            }
            endpoint.stop()
            self.endpoint = nil
            updateConnectedGrants()
        } else if isNeeded, !acceptsOutsideClients {
            // Outside access went off while a session keeps the channel: only the sessions' own connections stay.
            for connection in connections.values where connection.sessionID == nil { endpoint?.close(connection.id) }
            // A session an outside client started stops with its access.
            endClientSessions(of: nil, because: "Outside access was turned off in Arch.")
        }
    }

    private static let clientLeft = "The client left before the user answered."

    /// Ends a closed connection's calls and cards and forgets it.
    private func dropConnection(_ id: UUID, because reason: String) {
        outsidePrograms.connectionDidClose(id)
        for state in states.values { state.cancelCalls(onConnection: id) }
        approvals.end(connection: id, because: reason)
        connections.removeValue(forKey: id)?.cancelCalls()
    }

    /// Ends the sessions an outside client started, those of one grant or all of them, with their connections: a session never outlives the access that started it.
    private func endClientSessions(of grantID: UUID?, because reason: String) {
        for session in sessions where session.isFromOutsideClient && !session.hasEnded && (grantID == nil || session.grantID == grantID) {
            for connection in connections.values where connection.sessionID == session.id { endpoint?.close(connection.id) }
            Task {
                await session.end(keepingThread: keepsCodexCopy, because: reason)
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
        runsPerDaySave?.cancel()
        dependencies.prompt.cancelAll()
        runService?.cancelAll()
        for binding in hookCLIs.values {
            binding.finish()
            binding.runner?.endProcesses()
        }
        for session in sessions where !session.isCleanedUp { session.endProcessesAtQuit() }
        approvals.end(because: "Arch quit.")
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
        let isInForce = grantsInForce()
        return grants.first { $0.client.key == identity.key && isInForce($0) }
    }

    /// Whether a grant is in force now, as `grant(for:)` reads it, for the grants that events and hooks reach between expiry checks.
    func grantsInForce() -> (AgentGrant) -> Bool {
        let personas = Set(host.personas.map(\.id))
        let now = dependencies.now()
        return { [unowned self] in !$0.hasExpired(at: now) && !hasProcessEnded($0) && personas.contains($0.personaID) }
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

    /// Settings' agent runs a day for a grant with Start Agent Tasks, kept within 1 to 2,000. The sealed file is written once the number has not changed for a second, so that stepping writes it once; quit writes what is still waiting.
    public func setRunsPerDay(_ runs: Int, for grantID: UUID) {
        let runs = min(max(runs, AgentGrant.runsPerDayRange.lowerBound), AgentGrant.runsPerDayRange.upperBound)
        if let index = settings.grants.firstIndex(where: { $0.id == grantID }) {
            settings.grants[index].runsPerDay = runs
            runsPerDaySave?.cancel()
            runsPerDaySave = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.save()
            }
        } else if let index = launchGrants.firstIndex(where: { $0.id == grantID }) {
            launchGrants[index].runsPerDay = runs
        }
    }

    /// Ends a grant: its running calls stop, the client's connections get `revoked` and close, and its handles and events go. Its agent tabs stay in their folder, unsaved, until the user closes or keeps them or Arch quits.
    private func end(_ grant: AgentGrant, as event: AgentActivityEntry.Event, telling message: String, except connectionID: UUID? = nil) {
        let wasKept = settings.grants.contains { $0.id == grant.id }
        settings.grants.removeAll { $0.id == grant.id }
        launchGrants.removeAll { $0.id == grant.id }
        states[grant.id]?.cancelCalls()
        states[grant.id] = nil
        programGrantDidEnd(grant.id)
        approvals.end(owner: grant.id, because: message)
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
        // A rename changes the destination shown by an open draft or conversation.
        objectWillChange.send()
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

    /// The grant for a call from a client without one: the sheet, one at a time and at most once a minute after a refusal, then Touch ID where the choice needs it. Replies the error itself when there is none.
    private func grantForCall(from connection: ClientConnection, _ identity: AgentClientIdentity, requestID: AgentRPCID, call: ConnectionCall? = nil) async -> AgentGrant? {
        if let grant = grant(for: identity) { return grant }
        guard acceptsOutsideClients else {
            replyError(connection, requestID, Self.noGrantError("Outside access is off. Turn on Allow Outside Clients in Settings \u{25B8} AI \u{25B8} Agents."))
            return nil
        }
        if let declined = declinedAt[identity.key], dependencies.now().timeIntervalSince(declined) < Self.askInterval {
            replyError(connection, requestID, Self.noGrantError("You did not allow \(identity.displayName) to use Arch a moment ago. Arch asks again after a minute."))
            return nil
        }
        if questions[identity.key] == nil {
            if !questions.isEmpty {
                replyError(connection, requestID, Self.noGrantError("Arch is already asking about another program. Try again once that is answered."))
                return nil
            }
            if let declined = lastDeclinedAt, dependencies.now().timeIntervalSince(declined) < Self.askInterval {
                replyError(connection, requestID, Self.noGrantError("Arch asked about another program a moment ago and was not allowed. It asks again after a minute."))
                return nil
            }
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
            // A call the client cancelled while it waited on the sheet was answered then.
            if call?.isCancelled != true { replyError(connection, requestID, Self.noGrantError("You did not allow \(identity.displayName) to use Arch.")) }
            return nil
        }
        return grant
    }

    private func askForGrant(_ identity: AgentClientIdentity) async -> AgentGrant? {
        let agentsID = settings.agentsPersonaID.flatMap { id in host.personas.contains { $0.id == id } ? id : nil }
        let personas = host.personas.filter { $0.id != agentsID }
        let request = AgentGrantRequest(client: identity, personas: personas, agentsSpaces: agentsID.map(host.spaces(in:)) ?? [],
                                        spacesByPersona: Dictionary(uniqueKeysWithValues: personas.map { ($0.id, host.spaces(in: $0.id)) }))
        let answer = await dependencies.prompt.ask(request)
        // A sheet that closed because outside access went off records no decline and asks for no Touch ID.
        guard acceptsOutsideClients else { return nil }
        guard let choice = answer else {
            decline(identity)
            return nil
        }
        if choice.needsAuthentication {
            guard await dependencies.authenticator.authenticate(reason: "give \u{201C}\(identity.displayName)\u{201D} access to its agent tools") else {
                decline(identity)
                return nil
            }
        }
        // Outside access, or the Persona chosen, may have gone while the sheet showed.
        guard acceptsOutsideClients, let grant = makeGrant(choice, for: identity) else { return nil }
        // The client shows as connected now, also when the only call that waited on the sheet was cancelled meanwhile.
        updateConnectedGrants()
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
        lastDeclinedAt = dependencies.now()
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
        grantsInForceDidChange()
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

    /// A client's Stop, and Deny and Stop on one of its cards: cancels its running calls, denies its waiting cards, and disconnects it. Its grant stays.
    public func stopClient(_ grantID: UUID) {
        states[grantID]?.cancelCalls()
        approvals.end(owner: grantID, because: "The user stopped this client's work in Arch.")
        guard let grant = grants.first(where: { $0.id == grantID }) else { return }
        for connection in connections.values where connection.identity?.key == grant.client.key { endpoint?.close(connection.id) }
    }

    /// Shows a new card in the agent panel of the front main window, with its client's name, access, and place, and notifies while Arch is in the background, once while the client's cards wait.
    private func cardDidOpen(_ approval: AgentApproval) {
        if let session = session(withID: approval.ownerID) {
            session.setWaitingForAnswer(true)
        } else {
            if let grant = grants.first(where: { $0.id == approval.ownerID }) { describeInPanel(grant) }
            host.showAgentPanel(for: approval.ownerID)
        }
        if approvals.pending.allSatisfy({ $0.ownerID != approval.ownerID || $0.id == approval.id }) { dependencies.attention(approval.ownerID) }
    }

    public func pendingAttention(for ownerID: UUID) -> Bool {
        approvals.pending.contains { $0.ownerID == ownerID }
    }

    /// The panel's header for a grant: the client, its access, and its place as "Persona / Space".
    private func describeInPanel(_ grant: AgentGrant) {
        panel.describe(AgentPanelOwner(name: grant.client.displayName, access: grant.level.title, place: place(of: grant)), for: grant.id)
    }

    /// The grant's "Persona / Space", or its Persona alone while the Persona has no space.
    public func place(of grant: AgentGrant) -> String {
        let tools = toolHost()
        let persona = tools.personaName(of: grant)
        return tools.space(of: grant).map { "\(persona) / \($0.name)" } ?? persona
    }

    /// The tool host for a call on a connection, or for what agent tabs report, with the service's cards and waits.
    func toolHost(connectionID: UUID? = nil, callID: Int? = nil) -> AgentToolHost {
        var tools = AgentToolHost(host: host, allowsAI: dependencies.allowsAI, now: dependencies.now)
        tools.approvals = approvals
        tools.answerWait = dependencies.answerWait
        tools.approvalWindow = dependencies.approvalWindow
        tools.connectionID = connectionID
        tools.callID = callID
        // Deny and Stop on a session's card stops its turn; on an outside client's, it disconnects the client.
        tools.stopClient = { [weak self] ownerID in
            guard let self else { return }
            if let session = self.session(withID: ownerID) { session.stop() } else { self.stopClient(ownerID) }
        }
        return tools
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
        /// When a composer showed a specific document, refuse a changed page until the user reviews or removes the chip.
        var reviewedDocument: AgentTabInfo?
        var readerExcerpt: AgentReaderExcerpt?
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

    /// The panel lists only the user's eligible tabs in this app-started session's Persona.
    func shareableTabs(for session: AgentSession) -> [AgentTabInfo] {
        guard canEditAttachments(of: session) else { return [] }
        return host.userTabs(in: session.personaID).filter { tab in
            !session.handles.sharedTabIDs.contains(tab.id) && tab.canShareWithAgent(allowsAI: dependencies.allowsAI)
        }
    }

    func canEditAttachments(of session: AgentSession) -> Bool {
        self.session(withID: session.id) === session && session.origin == .app && !session.hasEnded
    }

    /// The composer may offer its detached tab again only while the originally reviewed document is eligible.
    func canReattach(_ choice: AgentTabInfo, in personaID: UUID) -> Bool {
        host.userTabs(in: personaID).contains {
            $0.showsSameDocument(as: choice) && $0.canShareWithAgent(allowsAI: dependencies.allowsAI)
        }
    }

    /// Recheck the choice against the live tab and document when the user picks it from the panel.
    @discardableResult func share(_ choice: AgentTabInfo, with session: AgentSession) -> Bool {
        guard let current = shareableTabs(for: session).first(where: { $0.showsSameDocument(as: choice) }) else { return false }
        _ = session.share(tabID: current.id, url: current.url)
        return true
    }

    /// Removal works even after the tab closes or becomes ineligible for reading.
    func stopSharing(_ tabID: UUID, with session: AgentSession) {
        guard canEditAttachments(of: session) else { return }
        session.unshare(tabID: tabID)
    }

    /// A read source remains local to its session. Choosing it can only select the same live document. Take Over and Hand Back change nothing here: they only refuse a read in progress, so the panel keeps listing what the session read, and a result an HTTP model's conversation already holds outlives them.
    func currentReadPage(_ page: AgentReadPage, in session: AgentSession) -> AgentTabInfo? {
        guard canEditAttachments(of: session), session.handles.tabs.id(for: page.handle) == page.tabID,
              let tab = host.tabs(withIDs: [page.tabID]).first, tab.documentID == page.documentID,
              tab.url == page.url, tab.isLoaded, tab.agentOwnerID == page.ownerID,
              AgentPolicy.mayRead(tab.url, allowsAI: dependencies.allowsAI) == .allowed else { return nil }
        if page.ownerID == session.id {
            guard host.agentTabs(of: session.id).contains(where: { $0.id == tab.id }) else { return nil }
        } else {
            guard page.ownerID == nil, session.handles.sharedTabIDs.contains(tab.id),
                  host.userTabs(in: session.personaID).contains(where: { $0.id == tab.id }) else { return nil }
        }
        return tab
    }

    /// The panel pauses its session and shows a tab it can still reach. An ended or detached session cannot change the visible tab.
    func takeOver(_ session: AgentSession, showTab: (UUID) -> Void) {
        guard self.session(withID: session.id) === session, !session.hasEnded, !session.isTakenOver else { return }
        session.takeOver()
        let owned = host.agentTabs(of: session.id)
        // The user acts in the session's tabs now, where no target check of an action that ended `stale` may cancel the user's input.
        let tools = toolHost()
        for tab in owned { tools.releaseInputCheck(in: tab.id) }
        let shared = host.userTabs(in: session.personaID).filter { $0.agentOwnerID == nil && session.handles.sharedTabIDs.contains($0.id) }
        let eligible = Set((owned + shared).map(\.id))
        let recent = session.items.reversed().lazy.compactMap { item -> UUID? in
            guard case .step(let step) = item.kind, step.status == .ok else { return nil }
            return step.tabID
        }
        if let tab = session.latestActiveTab, eligible.contains(tab) { showTab(tab) }
        else if let tab = recent.first(where: eligible.contains) ?? owned.first?.id ?? shared.first?.id { showTab(tab) }
    }

    /// The models that can run a session, the `agent` route's first, for the composer's menu.
    public func agentModels() -> [AIModelRef] {
        dependencies.agentModels()
    }

    /// Starts a session on the chosen model and sends its first message, which holds the task and the handles of the attached tabs. Throws a sentence when the space is gone or the Agents Persona cannot be recorded, and the runner's refusals, such as for a task that starts with `/`, which then stays in the composer.
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
        // No session starts above Settings' mode, which is Read Only while the seal is not checked, whatever its caller asks.
        let mode = start.mode.capped(at: newSessionMode)
        var scope = AgentSiteScope(searchResults: host.searchResultsAddress)
        let attachedIDs = Set(attached)
        let tabs = host.userTabs(in: personaID).filter { tab in
            attachedIDs.contains(tab.id) && tab.canShareWithAgent(allowsAI: dependencies.allowsAI)
        }
        if let reviewed = start.reviewedDocument, !tabs.contains(where: { $0.showsSameDocument(as: reviewed) }) {
            throw SessionError(message: "The attached page changed or is no longer available. Remove the attachment or reopen the composer for the current page.")
        }
        if let excerpt = start.readerExcerpt, !tabs.contains(where: excerpt.matches) {
            throw SessionError(message: "The source page changed or is no longer shared. Turn off Share reader excerpt to continue.")
        }
        tabs.compactMap(\.url).forEach { scope.add($0) }
        let session = AgentSession(title: AgentSession.title(forTask: start.task), personaID: personaID, spaceID: spaceID, origin: start.origin, mode: mode,
                                   model: start.model, effort: start.effort, scope: scope, attachedTabIDs: tabs.map(\.id), tools: [])
        session.readerExcerpt = start.readerExcerpt
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
        updateSessionsChannel()
        try session.send(start.task)
        return session
    }

    /// Chooses the session runner. Only a CLI runner receives a ticket, a working directory, and the bundled MCP tool.
    private func makeRunner(for session: AgentSession) throws -> any AgentSessionRunning {
        if !session.isFromOutsideClient, case .http(let model) = try dependencies.sessionRoute(session.requestedModel) {
            session.ticket = nil
            return AgentAPISession(client: dependencies.apiClient, tools: SessionTools(service: self, session: session), model: model, id: session.id)
        }
        let ticket = AgentSessionTicket.make()
        session.ticket = ticket
        let folder = dependencies.sessionFolder(session.id)
        let skills = AgentSessionSkills.skills(inSessionFolder: folder)
        let server = AIAgentToolServer(executable: dependencies.mcpExecutable, arguments: ["--session"], environment: [AgentMCPServer.ticketVariable: ticket.text], tools: session.reportedTools)
        let request = AIAgentSessionRequest(model: session.requestedModel, instructions: AgentHarness.sessionInstructions, toolServer: server, id: session.id, folder: folder, effort: session.effort, skills: skills)
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
        session.attachmentDidChange = { [weak approvals, id = session.id] tabID in
            guard let approvals else { return }
            for card in approvals.pending where card.ownerID == id {
                if case .shareSessionTab(let choices) = card.kind, choices.contains(where: { $0.id == tabID }) {
                    approvals.end(card.id, because: "The tabs available to share changed.")
                }
            }
        }
        session.dismissQuestions = { [weak approvals, id = session.id] in
            approvals?.end(owner: id, because: "The session stopped waiting for this answer.")
        }
        session.closeOwnedTabs = { [weak host, id = session.id] in
            guard let host else { return }
            for tab in host.agentTabs(of: id) { host.closeAgentTab(tab.id) }
        }
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
            if let name = dependencies.subscriptionToolName(provider) { return ("\(name) is not signed in.", .signIn(provider)) }
            return (error.localizedDescription, .openAISettings)
        case .rateLimited:
            return (dependencies.providerMessage(error), .retry)
        case .notConfigured, .budgetReached:
            return (error.localizedDescription, .openAISettings)
        case .blockedByPolicy(.agentMessageIsCommand):
            return (error.localizedDescription, nil)
        default:
            return (error.localizedDescription, .retry)
        }
    }

    /// Retry of the current failed message: a failed turn resends it on the same runner; a session that failed before any model held it gets a new runner first.
    public func retry(_ session: AgentSession, errorID: UUID? = nil) async {
        guard let currentError = session.transcript.retryableErrorID, errorID == nil || errorID == currentError else { return }
        guard !session.hasEnded, !restartingSessions.contains(session.id) else { return }
        guard case .failed = session.state else { return session.retryLastMessage() }
        guard session.model == nil, let old = session.runner else { return }
        restartingSessions.insert(session.id)
        defer { restartingSessions.remove(session.id) }
        let epoch = session.callEpoch
        await old.end(keepingThread: false)
        guard !session.hasEnded, session.callEpoch == epoch, !Task.isCancelled else { return }
        do {
            session.replaceRunner(try makeRunner(for: session), processRecord: dependencies.processRecord)
            updateSessionsChannel()
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
        await session.end(keepingThread: keepsCodexCopy)
        updateSessionsChannel()
    }

    /// Stop All Agents: every session's turn stops, its queued messages go, its running calls are cancelled, and its cards are denied; every outside client's running call is cancelled, every card that waits for the user is denied, which ends the calls waiting on it, and every outside client is disconnected; the grants stay.
    public func stopAllAgents() {
        runService?.cancelAll()
        for session in sessions where !session.hasEnded { session.stop() }
        for state in states.values { state.cancelCalls() }
        approvals.end(because: "The user stopped all agents in Arch.")
        for connection in connections.values where connection.sessionID == nil { endpoint?.close(connection.id) }
        didStopAll?()
    }

    /// Called at the end of Stop All Agents, from any menu, so that the app shell pauses the agent hooks too.
    public var didStopAll: (() -> Void)?

    /// Whether any agent acts now: a session's turn runs or an outside client is connected, for the bottom bar's indicator.
    public var isAnyAgentActing: Bool {
        runService?.isRunning == true || sessions.contains { $0.isTurnRunning } || !connectedGrantIDs.isEmpty
    }

    /// The spaces with a session that waits for the user, whose symbols in the bottom bar show a dot.
    public var spacesWaitingForUser: Set<UUID> {
        Set(sessions.filter { !$0.hasEnded && $0.state == .waitingForUser }.map(\.spaceID))
    }

    /// At quit, before the endpoint stops: every session ends, with its folder and Codex's thread, within `limit`; whatever is left ends its processes at `stop()`.
    public func endSessionsForQuit(within limit: Duration = .seconds(5)) async {
        let live = sessions.filter { !$0.hasEnded }
        guard !live.isEmpty else { return }
        let keepsCopy = keepsCodexCopy
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
                await session.end(keepingThread: keepsCodexCopy)
                updateSessionsChannel()
            }
        }
    }

    private func updateSessionsChannel() {
        sessionsNeedChannel = sessions.contains { !$0.hasEnded && $0.commandLineRunner != nil }
    }

    /// Where Use the Agents Persona starts a session, as "Persona / Space": the Agents Persona's first space, or the one Arch makes with it.
    public var agentsPersonaPlace: String {
        let id = settings.agentsPersonaID
        let persona = id.flatMap { id in host.personas.first { $0.id == id }?.name } ?? "Agents"
        let space = id.flatMap { host.spaces(in: $0).first?.name } ?? "Personal"
        return "\(persona) / \(space)"
    }

    /// The current names for these IDs. A session keeps its place after its Persona or space is deleted.
    private func place(personaID: UUID, spaceID: UUID, fallback: String? = nil) -> String {
        let persona = host.personas.first { $0.id == personaID }?.name
        let space = host.spaces(in: personaID).first { $0.id == spaceID }?.name
        if let fallback, persona == nil || space == nil { return fallback }
        return "\(persona ?? "Deleted Persona") / \(space ?? "Deleted Space")"
    }

    public func place(of session: AgentSession) -> String {
        place(personaID: session.personaID, spaceID: session.spaceID)
    }

    func place(of draft: AgentComposerContext) -> String {
        draft.usesAgentsPersona ? agentsPersonaPlace : place(personaID: draft.personaID, spaceID: draft.spaceID, fallback: draft.place)
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

    func startHookCLI(_ binding: AgentHookCLIRun, feature: AIFeatureID, models: [AIModelRef], turns: Int, instructions: String) throws -> any AgentSessionRunning {
        let server = AIAgentToolServer(executable: dependencies.mcpExecutable, arguments: ["--session"],
                                      environment: [AgentMCPServer.ticketVariable: binding.ticket.text], tools: binding.tools.map(\.name))
        var request = AIAgentSessionRequest(feature: feature, route: .models(models), instructions: instructions, toolServer: server, id: binding.id,
                                            folder: dependencies.sessionFolder(binding.id), maxTurns: turns, ephemeral: true)
        // A hook's run checks its known providers; an outside client's, which has none, checks none (`docs/hooks.md`, Known providers).
        request.knownProviders = binding.knownProviders.isEmpty ? nil : binding.knownProviders
        hookCLIs[binding.id] = binding
        if endpoint == nil { updateListening() }
        do {
            guard endpoint != nil else { throw AIError.invalidRequest(channelProblem ?? "The hook could not open its local tool connection.") }
            let runner = try dependencies.startRunner(request)
            runner.processDidStart = { [weak binding, record = dependencies.processRecord] pid in
                binding?.spawnedProcess = record(pid)
                binding?.ready.close()
            }
            binding.runner = runner
            return runner
        } catch {
            finishHookCLI(binding)
            throw error
        }
    }

    func finishHookCLI(_ binding: AgentHookCLIRun) {
        binding.finish()
        hookCLIs.removeValue(forKey: binding.id)
        for connection in connections.values where connection.sessionID == binding.id { endpoint?.close(connection.id) }
        if !acceptsOutsideClients, !sessionsNeedChannel, hookCLIs.isEmpty, shellHookRuns.isEmpty { updateListening() }
    }

    /// A ticket binds the connection to its session only when it matches one, compared with every session's and every hook run's in constant time, and the session's running CLI process, or the shell hook run's script process, is an ancestor of the peer by process ID and start time. Only `arch-mcp` presents a session's ticket and only `arch-cli` a shell hook run's. A ticket used from outside that tree is refused, logged, and noted in the session.
    private func bind(_ connection: ClientConnection, _ requestID: AgentRPCID, hello: AgentHello, ticket: String) {
        var matched: AgentSession?
        for session in sessions where session.ticket?.matches(ticket) == true && matched == nil { matched = session }
        var hookRun: AgentHookCLIRun?
        for binding in hookCLIs.values where binding.ticket.matches(ticket) && hookRun == nil { hookRun = binding }
        var shellRun: (id: UUID, access: ShellHookRunAccess)?
        for (id, access) in shellHookRuns where access.ticket.matches(ticket) && shellRun == nil { shellRun = (id, access) }
        let process = hookRun?.liveProcess ?? shellRun?.access.process ?? matched.flatMap { $0.hasEnded ? nil : $0.liveProcess }
        let id = hookRun?.id ?? shellRun?.id ?? matched?.id
        let presenter: AgentControl.AgentClientKind = shellRun == nil ? .mcp : .cli
        guard hello.client == presenter, let id, let process,
              AgentProcessAncestry.isProcess(connection.peer.processID, descendedFrom: process, records: dependencies.processRecord) else {
            if let session = matched, !session.hasEnded, hello.client == .mcp { session.noteForeignTicketUse() }
            activity.record(AgentActivityEntry(date: dependencies.now(), event: .refusedPeer, sessionID: id, clientName: hello.client.rawValue,
                                               outcome: id == nil ? "the ticket names no session" : "the ticket's program is not the session's"))
            // Only a shell hook's run gives `arch-cli` a ticket.
            let message = hello.client == .cli ? "No hook run in Arch has this ticket for this program." : "No agent session in Arch has this ticket for this program."
            return refuse(connection, requestID, AgentRefusal(reason: .ticket, message: message))
        }
        connection.hello = hello
        connection.sessionID = id
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
        AgentToolHost.sessionTools(for: session.mode, scopes: AgentGrantScopes(searchHistory: searchesHistory(session), startTasks: false))
            .filter { $0.name != "request_tab" || session.origin == .app }
            .map(\.name)
    }

    /// `tools/list` on a session's connection: the tools its mode allows. A list that differs from the last one reported, as after a mode change, reaches the runner, whose start check accepts it in a later `init`.
    private func listTools(for session: AgentSession) -> [String] {
        let tools = listedTools(for: session)
        if tools != session.reportedTools {
            session.reportedTools = tools
            session.commandLineRunner?.toolListDidChange(tools)
        }
        return tools
    }

    /// Sends `tools/changed` on the session's connections after its mode changed.
    private func toolsDidChange(forSession id: UUID) {
        for connection in connections.values where connection.stage == .ready && connection.sessionID == id {
            endpoint?.send(.notification(method: AgentControlMethod.toolsChangedNotification, params: nil), to: connection.id)
        }
    }

    /// A shell hook run's call, which the run's handler answers with the hook's grant and the run's tabs.
    private func callShellHook(_ run: ShellHookRunAccess, params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard connection.runningCalls < AgentLimits.callsPerConnection else {
            return replyError(connection, requestID, AgentRPCError(code: AgentControlErrorCode.busy, message: "This connection already runs \(AgentLimits.callsPerConnection) calls."))
        }
        guard let call = try? params?.decode(as: AgentToolCall.self) else {
            return replyError(connection, requestID, .invalidParams("tools/call needs a tool's name and its arguments."))
        }
        let running = connection.startCall(requestID)
        running.task = Task {
            defer { connection.endCall(running) }
            let result = run.tools.contains(call.name) ? await run.call(call)
                : AgentToolResult(status: .refused, code: "notGranted", text: "This hook's run cannot call \(call.name).")
            guard !running.isCancelled, connections[connection.id] != nil else { return }
            reply(connection, requestID, Self.json(result))
        }
    }

    private func callHook(_ hook: AgentHookCLIRun, params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard connection.runningCalls < AgentLimits.callsPerConnection else {
            return replyError(connection, requestID, AgentRPCError(code: AgentControlErrorCode.busy, message: "The connection has too many running calls."))
        }
        guard let call = try? params?.decode(as: AgentToolCall.self) else {
            return replyError(connection, requestID, .invalidParams("tools/call needs a tool's name and its arguments."))
        }
        let running = connection.startCall(requestID)
        running.task = Task {
            defer { connection.endCall(running) }
            let result = await hook.call(call)
            guard !running.isCancelled, connections[connection.id] != nil else { return }
            reply(connection, requestID, Self.json(result))
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
        let running = connection.startCall(requestID)
        let runner = session.commandLineRunner
        let epoch = session.callEpoch
        runner?.toolCallDidStart()
        running.task = Task {
            defer {
                connection.endCall(running)
                runner?.toolCallDidEnd()
            }
            // A call the client cancelled was answered then, and one cancelled before it ran ran nothing.
            let outcome = await sessionResult(of: call, in: session, arrivedAt: epoch, connectionID: connection.id, callID: running.callID) {
                !running.isCancelled && self.connections[connection.id] != nil
            }
            guard !running.isCancelled, connections[connection.id] != nil else { return }
            record(call, outcome: outcome, in: session)
            reply(connection, requestID, Self.json(outcome.result))
        }
    }

    /// A session's call as a step in its transcript, with the host's sentence for the tools that act, and as an entry in the activity log with its site and the user's decision.
    private func record(_ call: AgentToolCall, outcome: AgentToolHost.Outcome, in session: AgentSession) {
        let result = outcome.result
        let tool = AgentToolCatalog.sessionTool(named: call.name)
        let tabHandle = result.structured?["tab"]?.stringValue ?? call.arguments["tab"]?.stringValue
        session.record(AgentStepText.step(for: call, result: result, tabHandle: tabHandle, tabID: tabHandle.flatMap(session.handles.tabs.id(for:)), hostStep: outcome.step))
        let decision: AgentActivityEntry.Decision
        switch (call.name, result.status) {
        case (_, .refused): decision = .refused
        case ("ask_user", .ok), ("request_tab", .ok): decision = .approved
        case ("ask_user", .denied), ("request_tab", .denied): decision = .denied
        case ("ask_user", .timeout), ("request_tab", .timeout): decision = .timedOut
        default: decision = outcome.decision ?? .auto
        }
        activity.record(AgentActivityEntry(date: dependencies.now(), event: .toolCall, grantID: session.grantID, sessionID: session.id, clientName: session.clientName,
                                           personaID: session.personaID, tool: tool?.name, toolClass: tool?.toolClass.rawValue, site: outcome.site,
                                           decision: decision, rule: result.status == .refused ? result.code : nil, outcome: result.status.rawValue))
    }

    /// The tool host bound to a session, as an HTTP session's loop runs it; tests run a CLI session's calls through it too.
    func sessionTools(for session: AgentSession) -> any AgentSessionTools {
        SessionTools(service: self, session: session)
    }

    /// Binds the HTTP tool loop to this session for its full lifetime, without a peer, a ticket, or a socket.
    @MainActor private final class SessionTools: AgentSessionTools {
        weak var service: AgentService?
        weak var session: AgentSession?

        init(service: AgentService, session: AgentSession) {
            self.service = service
            self.session = session
        }

        var tools: [AgentTool] {
            guard let service, let session else { return [] }
            return service.listedTools(for: session).compactMap(AgentToolCatalog.sessionTool(named:))
        }

        func historyCheck(for call: AgentToolCall) -> (@MainActor @Sendable (AIToolResult) -> AIToolResult)? {
            guard let service, let session else { return nil }
            let host = service.host
            let tabs: [AgentTabInfo]
            switch call.name {
            case "read_text", "snapshot":
                tabs = call.arguments["tab"]?.stringValue.flatMap(session.handles.tabs.id(for:)).map { host.tabs(withIDs: [$0]) } ?? []
            case "session_info":
                tabs = session.readerExcerpt.map { host.tabs(withIDs: [$0.tabID]) } ?? []
            case "list_tabs":
                let shared = Set(session.handles.sharedTabIDs)
                tabs = call.arguments["scope"]?.stringValue == "shared" ? host.userTabs(in: session.personaID).filter { shared.contains($0.id) } : host.agentTabs(of: session.id)
            default: return nil
            }
            // Handles are never reused, including when the user shares the same tab again.
            let pages = tabs.compactMap { tab -> AgentReadPage? in
                guard let url = tab.url else { return nil }
                return AgentReadPage(tabID: tab.id, handle: session.handles.tabs.handle(for: tab.id), documentID: tab.documentID,
                                     url: url, ownerID: tab.agentOwnerID)
            }
            let sources = Dictionary(uniqueKeysWithValues: pages.map { ($0.handle, $0) })
            return { [weak service, weak session] result in
                @MainActor func permits(_ handle: String) -> Bool {
                    guard let service, let session, let source = sources[handle] else { return false }
                    return service.currentReadPage(source, in: session) != nil
                }
                if call.name == "list_tabs" {
                    return Self.checkedList(result, permits: permits)
                }
                if let handle = sources.keys.first, permits(handle) { return result }
                return Self.withheld(result)
            }
        }

        private static func withheld(_ result: AIToolResult) -> AIToolResult {
            AIToolResult(callID: result.callID, parts: [.text("Arch withheld this earlier result because access to its page changed.")], isError: true)
        }

        /// The host emits one marked title per visible row, with its handle immediately before it
        /// and its host or address immediately after it. Keep these together when a grant changes.
        private static func checkedList(_ result: AIToolResult, permits: (String) -> Bool) -> AIToolResult {
            var copy = result
            var changed = false
            for index in result.parts.indices {
                guard case .page = result.parts[index] else { continue }
                guard index > 0, index + 1 < result.parts.count, case .text(let prefix) = result.parts[index - 1],
                      case .text(let suffix) = result.parts[index + 1],
                      let handle = prefix.components(separatedBy: "\n").last?.trimmingCharacters(in: .whitespaces) else { return withheld(result) }
                if !permits(handle) {
                    copy.parts[index] = .text("(page access changed)")
                    copy.parts[index + 1] = .text(suffix.firstIndex(of: "\n").map { String(suffix[$0...]) } ?? "")
                    changed = true
                }
            }
            return changed ? copy : result
        }

        func run(_ call: AgentToolCall) async -> AgentToolResult {
            guard let service, let session, !session.hasEnded else { return AgentToolResult(status: .refused, code: "stopped", text: "The session ended.") }
            let outcome = await service.sessionResult(of: call, in: session, arrivedAt: session.callEpoch)
            if !Task.isCancelled { service.record(call, outcome: outcome, in: session) }
            return outcome.result
        }
    }

    /// Shared permission, turn, and budget checks for CLI and HTTP sessions.
    private func sessionResult(of call: AgentToolCall, in session: AgentSession, arrivedAt epoch: Int, connectionID: UUID? = nil, callID: Int? = nil,
                               isConnected: () -> Bool = { true }) async -> AgentToolHost.Outcome {
        // The call's waits for the user, while the session is taken over and on its cards, share one time from its arrival, so that it answers before the CLI's tool timeout.
        let deadline = dependencies.now().addingTimeInterval(sessionQuestionWindow)
        guard await session.ready.wait(timeout: sessionReadyWait) else {
            if Task.isCancelled { return AgentToolHost.ended }
            if let stale = session.staleCallResult(arrivedAt: epoch) { return AgentToolHost.Outcome(result: stale) }
            return AgentToolHost.Outcome(result: AgentToolResult(status: .refused, code: "notReady", text: "Arch did not see the session's tool start as it asked, so it runs none of this session's tool calls."))
        }
        // A call the turn's end or Stop cut off, or whose connection closed while it waited, runs nothing.
        if let stale = session.staleCallResult(arrivedAt: epoch) { return AgentToolHost.Outcome(result: stale) }
        guard await session.handedBack.wait(timeout: min(sessionTakeOverWait, .seconds(max(0, deadline.timeIntervalSince(dependencies.now()))))) else {
            if Task.isCancelled { return AgentToolHost.ended }
            if let stale = session.staleCallResult(arrivedAt: epoch) { return AgentToolHost.Outcome(result: stale) }
            return AgentToolHost.Outcome(result: AgentToolResult(status: .timeout, text: session.hasEnded ? "The session ended." : "The user took the session over and has not handed it back. Wait for the user's next message."))
        }
        if let stale = session.staleCallResult(arrivedAt: epoch) { return AgentToolHost.Outcome(result: stale) }
        guard !Task.isCancelled, isConnected() else {
            return AgentToolHost.Outcome(result: AgentToolResult(status: .refused, code: "stopped", text: "The call was cancelled."))
        }
        if let refusal = session.countCall() { return AgentToolHost.Outcome(result: refusal) }
        var toolHost = toolHost(connectionID: connectionID, callID: callID)
        toolHost.approvalWindow = sessionQuestionWindow
        toolHost.callDeadline = deadline
        let generation = session.takeoverGeneration
        let read: AgentReadPage?
        if session.origin == .app, call.name == "snapshot" || call.name == "read_text",
           let handle = call.arguments["tab"]?.stringValue, let id = session.handles.tabs.id(for: handle),
           let tab = host.tabs(withIDs: [id]).first, let url = tab.url {
            read = AgentReadPage(tabID: id, handle: handle, documentID: tab.documentID, url: url, ownerID: tab.agentOwnerID)
        } else {
            read = nil
        }
        let outcome: AgentToolHost.Outcome
        if call.name == "request_tab" {
            outcome = AgentToolHost.Outcome(result: await requestSharedTab(call, in: session, epoch: epoch, generation: generation, connectionID: connectionID, deadline: deadline, isConnected: isConnected))
        } else {
            outcome = await toolHost.runSession(call, in: session, searchesHistory: searchesHistory(session))
        }
        if !approvals.pending.contains(where: { $0.ownerID == session.id }) {
            session.setWaitingForAnswer(false)
        }
        // The decision stays with a call whose card the user answered before its turn ended.
        func refused(_ result: AgentToolResult) -> AgentToolHost.Outcome {
            AgentToolHost.Outcome(result: result, site: outcome.site, decision: outcome.decision)
        }
        if Task.isCancelled || !isConnected() { return refused(AgentToolHost.ended.result) }
        if let stale = session.staleCallResult(arrivedAt: epoch) { return refused(stale) }
        if session.isTakenOver || generation != session.takeoverGeneration {
            return refused(AgentToolResult(status: .refused, code: "stopped", text: "The user took over while this call was running. Request the step again when the user hands the session back."))
        }
        if outcome.result.status == .ok, let read, currentReadPage(read, in: session) != nil {
            session.recordRead(read)
        }
        return outcome
    }

    /// The card keeps local titles and addresses. Only the resulting read handle goes to the model.
    private func requestSharedTab(_ call: AgentToolCall, in session: AgentSession, epoch: Int, generation: Int,
                                  connectionID: UUID?, deadline: Date, isConnected: () -> Bool) async -> AgentToolResult {
        guard canEditAttachments(of: session) else {
            return AgentToolResult(status: .refused, code: "notAvailable", text: "Only a task started in Arch can ask to share a tab here.")
        }
        if let problem = AgentToolHost.problem(with: call.arguments, for: AgentToolCatalog.sessionTabRequest) {
            return AgentToolResult(status: .error, code: "invalidArguments", text: problem)
        }
        guard session.acceptsQuestions, session.isTurnRunning else { return AgentToolHost.ended.result }
        let choices = shareableTabs(for: session)
        // No card asked the user, so nothing reads as their refusal.
        guard !choices.isEmpty else { return AgentToolResult(status: .refused, code: "notAvailable", text: "No other eligible tab is open in this Persona.") }
        let now = dependencies.now()
        let card = AgentApproval(ownerID: session.id, clientName: session.title, isOutsideClient: false,
                                 kind: .shareSessionTab(choices), isSensitive: false, offers: [.deny],
                                 action: "Choose a tab for this session to read", agentSays: call.arguments["reason"]?.stringValue,
                                 connectionID: connectionID, createdAt: now, deadline: min(now.addingTimeInterval(sessionQuestionWindow), deadline))
        let answer = await approvals.request(card)
        guard !Task.isCancelled, isConnected(), session.callEpoch == epoch, session.takeoverGeneration == generation,
              session.acceptsQuestions, !session.isTakenOver, !session.hasEnded else { return AgentToolHost.ended.result }
        if answer == .timedOut { return AgentToolResult(status: .timeout, code: "notAnswered", text: "The user did not answer the tab request in time.") }
        if case .ended = answer { return AgentToolResult(status: .stale, code: "stale", text: "The tabs available to share changed. No tab was shared.") }
        guard case .tab(let id) = answer else { return AgentToolResult(status: .denied, text: "No tab was shared.") }
        guard let choice = choices.first(where: { $0.id == id }), share(choice, with: session) else {
            return AgentToolResult(status: .stale, code: "stale", text: "The reviewed tab changed. No tab was shared.")
        }
        let handle = session.handles.tabs.handle(for: id)
        return AgentToolResult(status: .ok, text: "The user shared \(handle) for reading.", structured: ["tab": .string(handle), "access": "read"])
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
            plan = try AgentTaskPlan.make(for: start, grant: grant, spaces: host.spaces(in: grant.personaID), models: dependencies.agentModels().filter { dependencies.subscriptionToolName($0.provider) != nil }, settingsDefault: newSessionMode)
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
                            model: session.model.map { "\(dependencies.subscriptionToolName($0.provider) ?? $0.provider.rawValue) \u{2014} \(aiModelTitle($0.model))" })
    }

    // MARK: Messages

    private func handle(_ message: AgentRPCMessage, on connection: ClientConnection) {
        // Arch acts on a client's `tools/cancel` and asks clients nothing.
        if case .notification(let method, let params) = message, method == AgentControlMethod.toolsCancelNotification, connection.stage == .ready {
            return cancelCall(params, on: connection)
        }
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
                if let hook = hookCLIs[sessionID] {
                    return reply(connection, requestID, Self.json(AgentToolList(tools: hook.tools.map(\.name))))
                }
                if let run = shellHookRuns[sessionID] { return reply(connection, requestID, Self.json(AgentToolList(tools: run.tools))) }
                guard let session = session(withID: sessionID) else { return closeConnection(connection) }
                return reply(connection, requestID, Self.json(AgentToolList(tools: listTools(for: session))))
            }
            let grant = connection.identity.flatMap(grant(for:))
            let tools = grant.map { AgentToolHost.tools(for: $0.level, scopes: $0.scopes) } ?? AgentToolHost.toolsBeforeGrant
            reply(connection, requestID, Self.json(AgentToolList(tools: tools.map(\.name) + Self.programTools(for: grant))))
        case (.ready, AgentControlMethod.toolsCall):
            if let sessionID = connection.sessionID {
                if let hook = hookCLIs[sessionID] { return callHook(hook, params: params, on: connection, requestID: requestID) }
                if let run = shellHookRuns[sessionID] { return callShellHook(run, params: params, on: connection, requestID: requestID) }
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
        case (.ready, AgentControlMethod.eventsSubscribe) where connection.sessionID == nil:
            subscribeEvents(params, on: connection, requestID: requestID)
        case (.ready, AgentControlMethod.eventsUnsubscribe) where connection.sessionID == nil:
            unsubscribeEvents(params, on: connection, requestID: requestID)
        case (.ready, AgentControlMethod.hooksList) where connection.sessionID == nil, (.ready, AgentControlMethod.hooksAdd) where connection.sessionID == nil,
             (.ready, AgentControlMethod.hooksRemove) where connection.sessionID == nil:
            hookCall(method, params, on: connection, requestID: requestID)
        case (.ready, AgentControlMethod.agentRun) where connection.sessionID == nil:
            runAgent(params, on: connection, requestID: requestID)
        case (.ready, AgentControlMethod.agentRun):
            runShellHookAgent(params, on: connection, requestID: requestID)
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
        // A shell hook's run reaches Arch only through its ticket, so a command in the run that dropped `ARCH_HOOK_TICKET`, as `env -i` does, never becomes an outside client shown as Arch's terminal.
        if let run = shellHookRun(containing: connection.peer.processID) {
            activity.record(AgentActivityEntry(date: dependencies.now(), event: .refusedPeer, sessionID: run, clientName: hello.client.rawValue,
                                               outcome: "a program in a hook's run presented no ticket"))
            return refuse(connection, requestID, AgentRefusal(reason: .ticket, message: "Programs in a hook's run reach Arch only with the run's ticket."))
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
        // The grant's space, or the Persona's first space once that one is gone, as the tool host takes it.
        let spaces = host.spaces(in: grant.personaID)
        let space = (spaces.first { $0.id == grant.spaceID } ?? spaces.first)?.name
        return AgentHelloAnswer(version: version, status: .granted(AgentGrantSummary(level: grant.level, persona: persona, space: space, expiry: grant.expiry)))
    }

    private func call(_ params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard let identity = connection.identity else { return }
        guard connection.runningCalls < AgentLimits.callsPerConnection else {
            return replyError(connection, requestID, AgentRPCError(code: AgentControlErrorCode.busy, message: "This connection already runs \(AgentLimits.callsPerConnection) calls."))
        }
        guard let call = try? params?.decode(as: AgentToolCall.self) else {
            return replyError(connection, requestID, .invalidParams("tools/call needs a tool's name and its arguments."))
        }
        let running = connection.startCall(requestID)
        if call.name == "approval_wait" { running.waitsOn = call.arguments["approval"]?.stringValue }
        running.task = Task {
            defer { connection.endCall(running) }
            guard let grant = await grantForCall(from: connection, identity, requestID: requestID, call: running), connections[connection.id] != nil, !running.isCancelled else { return }
            updateConnectedGrants()
            if usedThisLaunch.insert(grant.id).inserted { record(.firstUse, grant: grant) }
            touch(grant)
            describeInPanel(grant)
            let outcome = await runOutsideCall(call, for: grant, connectionID: connection.id, callID: running.callID)
            let result = outcome.result
            if call.name == "approval_wait" {
                // A plain read: the call it waited on records its own entry and step when it ends.
                recordCall(outcome, of: call, for: grant, client: identity.displayName, decision: .auto)
            } else if result.status == .approvalPending, let waiting = outcome.waitingCall {
                // The call goes on: it records what it did, with the user's decision, when it ends, whether or not the client calls approval_wait.
                recordCall(outcome, of: call, for: grant, client: identity.displayName, decision: .pending)
                waiting.whenFinished { final in
                    self.recordCall(final, of: call, for: grant, client: identity.displayName)
                    self.recordStep(final, of: call, for: grant)
                }
            } else {
                recordCall(outcome, of: call, for: grant, client: identity.displayName)
                recordStep(outcome, of: call, for: grant)
            }
            // A call the client cancelled was answered then.
            guard !running.isCancelled else { return }
            reply(connection, requestID, Self.json(result))
        }
    }

    /// A client's `tools/cancel` for a call on this connection: the call stops waiting, whether on its card, which is withdrawn, on the grant sheet, which stays open for the client's next call, or on an in-app session's gates, runs no further step, ends with status `error` and code `cancelled`, which `arch-mcp` drops, and frees its slot. An `approval_wait` cancels the call it waits on too, whose card is withdrawn, so that the step never runs once the client stopped waiting for it. A call that has ended, or one of another connection, is left alone.
    private func cancelCall(_ params: AgentJSON?, on connection: ClientConnection) {
        guard let cancel = try? params?.decode(as: AgentToolCancel.self), let running = connection.cancelCall(cancel.call) else { return }
        for state in Array(states.values) + sessions.map(\.toolState) {
            for card in state.cancelCall(cancel.call, onConnection: connection.id) { approvals.end(card, because: "The client cancelled the call.") }
        }
        // Handles are the grant's, so the call waited on is one of this client's.
        if let handle = running.waitsOn, let grant = connection.identity.flatMap(grant(for:)), let card = states[grant.id]?.cancelPendingCall(handle) {
            approvals.end(card, because: "The client cancelled the call.")
        }
        reply(connection, .number(cancel.call), Self.json(AgentToolResult(status: .error, code: "cancelled", text: "The client cancelled the call, so Arch stopped it.")))
        running.task?.cancel()
    }

    /// A call's entry in the activity log: its tool and class, the site, and the decision, the given one or else the refusal's or the outcome's.
    private func recordCall(_ outcome: AgentToolHost.Outcome, of call: AgentToolCall, for grant: AgentGrant, client: String, decision given: AgentActivityEntry.Decision? = nil) {
        let result = outcome.result
        let tool = AgentToolCatalog.tool(named: call.name)
        let decision = given ?? (result.status == .refused ? .refused : outcome.decision ?? .auto)
        activity.record(AgentActivityEntry(date: dependencies.now(), event: .toolCall, grantID: grant.id, clientName: client, personaID: grant.personaID,
                                           tool: tool?.name, toolClass: tool?.toolClass.rawValue, site: outcome.site, decision: decision,
                                           rule: decision == .refused ? result.code : nil, outcome: result.status.rawValue))
    }

    // MARK: Agent tabs

    /// The tool host's record of a grant, made at its first call this launch with today's calls from the activity log.
    private func state(for grant: AgentGrant) -> AgentGrantState {
        if let state = states[grant.id] { return state }
        let state = AgentGrantState()
        let now = dependencies.now()
        state.seedCalls(activity.callsToday(of: grant.id, at: now), at: now)
        states[grant.id] = state
        return state
    }

    /// What the tool host keeps for an owner of agent tabs: a grant's state from its first call, or a session's own.
    private func toolState(of ownerID: UUID) -> AgentGrantState? {
        states[ownerID] ?? session(withID: ownerID)?.toolState
    }

    /// What an agent tab reported, for its owner's next result and cards. Each document a session's agent tab finishes is an address the session has seen (Site scope and navigation).
    private func agentTab(_ tabID: UUID, of ownerID: UUID, didReport report: AgentTabReport) {
        let session = session(withID: ownerID)
        switch report {
        case .takenOver, .closed, .loaded, .addressChanged:
            if let session, session.transcript.containsRead(of: tabID) { session.objectWillChange.send() }
        default: break
        }
        if let session, !session.hasEnded, case .loaded(let url?, _) = report { session.scope.see(url) }
        let client = session.map { AgentToolClient(session: $0, searchesHistory: false) } ?? grants.first { $0.id == ownerID }.map(AgentToolClient.init(grant:))
        var tools = toolHost()
        // A session's cards about its pages' downloads and links to other apps wait as long as its other cards.
        if session != nil { tools.approvalWindow = sessionQuestionWindow }
        tools.tab(tabID, of: ownerID, didReport: report, state: toolState(of: ownerID), client: client)
    }

    /// A file chooser of a page in an agent tab, which asks on its owner's P7 card and waits as long as the owner's other cards that a page starts. A session that has ended gives the page no file.
    private func agentTab(_ tabID: UUID, of ownerID: UUID, choosesFiles chooser: AgentFileChooser) {
        let session = session(withID: ownerID)
        if session?.hasEnded == true { return chooser.deny() }
        let client = session.map { AgentToolClient(session: $0, searchesHistory: false) } ?? grants.first { $0.id == ownerID }.map(AgentToolClient.init(grant:))
        var tools = toolHost()
        if session != nil { tools.approvalWindow = sessionQuestionWindow }
        tools.askAboutFileChooser(chooser, in: tabID, of: ownerID, state: toolState(of: ownerID), client: client)
    }

    private func agentTab(_ tabID: UUID, of ownerID: UUID, mayLoad url: URL, kind: AgentLoadKind) -> Bool {
        toolHost().tab(tabID, mayLoad: url, kind: kind, state: toolState(of: ownerID), scope: session(withID: ownerID)?.scope)
    }

    /// A call's step in the agent panel: the tool host's sentence for the user, or the tool and its tab, with how it ended.
    private func recordStep(_ outcome: AgentToolHost.Outcome, of call: AgentToolCall, for grant: AgentGrant) {
        let handle = call.arguments["tab"]?.stringValue ?? outcome.result.structured?["tab"]?.stringValue
        let tabID = handle.flatMap { states[grant.id]?.handles.tabs.id(for: $0) }
        let name = call.name.replacingOccurrences(of: "_", with: " ")
        var sentence = outcome.step ?? (name.prefix(1).uppercased() + name.dropFirst() + (handle.map { " \($0)" } ?? "") + (outcome.site.map { " on \($0)" } ?? ""))
        if outcome.result.status != .ok { sentence += " \u{2014} \(outcome.result.status.rawValue)\(outcome.result.code.map { " (\($0))" } ?? "")" }
        panel.record(AgentStepRecord(date: dependencies.now(), sentence: sentence, tabID: tabID, tabHandle: handle, status: outcome.result.status,
                                     addressesAgents: outcome.result.structured?["addressesAgents"] == .bool(true)), for: grant.id)
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
    /// The calls that run on the connection by their request ID, which a client's `tools/cancel` names.
    private var calls: [AgentRPCID: ConnectionCall] = [:]

    init(id: UUID, peer: AgentPeer) {
        self.id = id
        self.peer = peer
    }

    /// A call takes one of the connection's slots until it ends or the client cancels it.
    func startCall(_ requestID: AgentRPCID) -> ConnectionCall {
        let call = ConnectionCall(requestID: requestID)
        runningCalls += 1
        calls[requestID] = call
        return call
    }

    /// Frees the call's slot unless `tools/cancel` freed it.
    func endCall(_ call: ConnectionCall) {
        guard !call.isCancelled else { return }
        runningCalls -= 1
        if calls[call.requestID] === call { calls[call.requestID] = nil }
    }

    func cancelCalls() {
        for call in calls.values {
            call.isCancelled = true
            call.task?.cancel()
        }
        calls.removeAll()
        runningCalls = 0
    }

    /// The running call that `tools/cancel` names, marked cancelled with its slot freed, or nil once it has ended.
    func cancelCall(_ callID: Int) -> ConnectionCall? {
        guard let call = calls.removeValue(forKey: .number(callID)), !call.isCancelled else { return nil }
        call.isCancelled = true
        runningCalls -= 1
        return call
    }
}

/// One `tools/call` on a connection, which its client may cancel.
private final class ConnectionCall {
    /// The call's JSON-RPC request ID, by which the connection tracks it.
    let requestID: AgentRPCID
    /// The request ID, when it is a number, as `tools/cancel` names calls.
    let callID: Int?
    var task: Task<Void, Never>?
    var isCancelled = false
    /// For `approval_wait`, the handle of the call it waits on, which the client's `tools/cancel` of it cancels too.
    var waitsOn: String?

    init(requestID: AgentRPCID) {
        self.requestID = requestID
        if case .number(let number) = requestID { callID = number } else { callID = nil }
    }
}

extension AIFeature {
    /// Agent Tasks (docs/agents.md, Model choice and fallbacks): sessions the user starts, whose page data reaches the model only as tool results that Arch checks. Its route lists only models that can run a session.
    public static let agent = AIFeature(id: .agent, name: "Agent Tasks",
                                        summary: "Runs browser sessions on your connected model with Arch’s tools and permissions.",
                                        trigger: .user, data: AIDataScope(kinds: [.page, .selection, .file]), requirements: [.agent])
}

// MARK: - Shell hook runs

/// A shell hook run's access to Arch through `arch-cli` (`docs/hooks.md`, Shell scripts ▸ Acting): the run's ticket, which the script's environment carries as `ARCH_HOOK_TICKET`, binds a connection only from the run's script process or its descendants, and only while the run lasts. The socket listens meanwhile, as for an in-app session on a CLI. `Hooks` runs the scripts and answers their calls; `AgentService` keeps the tickets and binds the connections.
@MainActor
public protocol AgentHookRunChannel: AnyObject {
    /// Opens the run's access and returns its ticket: its connections list `tools`, and `call` answers each of their calls to one of them.
    func openHookRun(_ run: UUID, tools: [String], call: @escaping @MainActor (AgentToolCall) async -> AgentToolResult) -> String
    /// The same, with `agentRun` answering the connections' `agent/run` under the hook's grant, feature, and run tabs (`docs/hooks.md`, arch-cli agent run and rename), whose answer names each renamed tab by its handle in `handles`, the run tabs' handles; without `agentRun`, `agent/run` is refused.
    func openHookRun(_ run: UUID, tools: [String], handles: [UUID: String], call: @escaping @MainActor (AgentToolCall) async -> AgentToolResult,
                     agentRun: (@MainActor ([String: AgentJSON]) async -> AgentRunResult)?) -> String
    /// The run's script process started; connections bind only from it and its descendants.
    func hookRun(_ run: UUID, didStart processID: pid_t)
    /// The run ended: its ticket binds nothing more, and its connections close.
    func closeHookRun(_ run: UUID)
}

extension AgentHookRunChannel {
    /// A channel that serves no `agent/run` opens the run's access without it.
    public func openHookRun(_ run: UUID, tools: [String], handles: [UUID: String], call: @escaping @MainActor (AgentToolCall) async -> AgentToolResult,
                            agentRun: (@MainActor ([String: AgentJSON]) async -> AgentRunResult)?) -> String {
        openHookRun(run, tools: tools, call: call)
    }
}

/// A shell hook run as the service keeps it.
@MainActor
private final class ShellHookRunAccess {
    let ticket = AgentSessionTicket.make()
    let tools: [String]
    let call: @MainActor (AgentToolCall) async -> AgentToolResult
    /// The run's `agent/run`, when its hook may start agent runs.
    let agentRun: (@MainActor ([String: AgentJSON]) async -> AgentRunResult)?
    /// The run tabs' handles, by which `agent/run`'s answer names the tabs it renamed.
    let handles: [UUID: String]
    /// The script process, as it was right after it started.
    var process: AgentProcessRecord?

    init(tools: [String], handles: [UUID: String] = [:], call: @escaping @MainActor (AgentToolCall) async -> AgentToolResult,
         agentRun: (@MainActor ([String: AgentJSON]) async -> AgentRunResult)? = nil) {
        self.tools = tools
        self.handles = handles
        self.call = call
        self.agentRun = agentRun
    }
}

extension AgentService {
    /// The shell hook run whose script process is the peer or one of its ancestors, by process ID and start time.
    func shellHookRun(containing processID: pid_t) -> UUID? {
        shellHookRuns.first { _, access in
            access.process.map { AgentProcessAncestry.isProcess(processID, descendedFrom: $0, records: dependencies.processRecord) } ?? false
        }?.key
    }
}

extension AgentService: AgentHookRunChannel {
    public func openHookRun(_ run: UUID, tools: [String], call: @escaping @MainActor (AgentToolCall) async -> AgentToolResult) -> String {
        openHookRun(run, tools: tools, handles: [:], call: call, agentRun: nil)
    }

    public func openHookRun(_ run: UUID, tools: [String], handles: [UUID: String], call: @escaping @MainActor (AgentToolCall) async -> AgentToolResult,
                            agentRun: (@MainActor ([String: AgentJSON]) async -> AgentRunResult)?) -> String {
        let access = ShellHookRunAccess(tools: tools, handles: handles, call: call, agentRun: agentRun)
        shellHookRuns[run] = access
        if endpoint == nil { updateListening() }
        return access.ticket.text
    }

    public func hookRun(_ run: UUID, didStart processID: pid_t) {
        shellHookRuns[run]?.process = dependencies.processRecord(processID)
    }

    public func closeHookRun(_ run: UUID) {
        guard shellHookRuns.removeValue(forKey: run) != nil else { return }
        for connection in connections.values where connection.sessionID == run { endpoint?.close(connection.id) }
        if !acceptsOutsideClients, !sessionsNeedChannel, hookCLIs.isEmpty, shellHookRuns.isEmpty { updateListening() }
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
        dropConnection(connection, because: Self.clientLeft)
        updateConnectedGrants()
    }

    func endpoint(_ endpoint: AgentEndpoint, didRefusePeer name: String, reason: String) {
        activity.record(AgentActivityEntry(date: dependencies.now(), event: .refusedPeer, clientName: name, outcome: reason))
    }
}

// MARK: - Outside programs

extension AgentService {
    /// The session's bus, whose events reach the grants with Watch Browser Events through the outside view (`docs/hooks.md`, Outside programs). The app shell attaches it once both exist.
    public func attach(events bus: BrowserEventBus) {
        outsidePrograms.busSubscription?.cancel()
        outsidePrograms.busSubscription = bus.subscribe(BrowserEventFilter(tabKinds: Set(BrowserTabKind.allCases))) { [weak self] event in self?.deliver(event) }
    }

    /// The tools of outside programs beside the tool host's: `watch_events` with Watch Browser Events, and before a grant, since the grant sheet may allow it.
    static func programTools(for grant: AgentGrant?) -> [String] {
        [AgentToolCatalog.renameTab.name] + (grant.map { $0.scopes.watchEvents } ?? true ? [AgentToolCatalog.watchEvents.name] : [])
    }

    /// Records the event in each watching grant's buffer and queues it for that grant's subscriptions that take it. While outside access is off, no grant records anything.
    private func deliver(_ event: BrowserEvent) {
        guard acceptsOutsideClients else { return }
        // A grant whose time is up gets nothing more, also before the next expiry check ends it.
        let isInForce = grantsInForce()
        for grant in grants where grant.scopes.watchEvents && isInForce(grant) {
            let buffer = outsidePrograms.buffer(for: grant.id)
            let reader = AgentEventReader(grant: grant, state: state(for: grant), buffer: buffer, ownTabs: Set(host.agentTabs(of: grant.id).map(\.id)), allowsAI: dependencies.allowsAI)
            guard let view = reader.view(of: event) else {
                buffer.passed(event.sequence)
                continue
            }
            let buffered = AgentBufferedEvent(event: event, view: view)
            buffer.append(buffered)
            for (connectionID, events) in outsidePrograms.subscriptions where events.grantID == grant.id {
                events.enqueue(buffered, allowsAI: dependencies.allowsAI)
                scheduleFlush(of: connectionID, events)
            }
        }
    }

    /// `events/subscribe`: asks for a grant first, as a tool call does, needs Watch Browser Events, checks the filter against the grant's Persona, and answers with the subscription and the last sequence before replaying the buffered events after `after`.
    private func subscribeEvents(_ params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard let identity = connection.identity else { return }
        guard let subscribe = try? (params ?? .object([:])).decode(as: AgentEventSubscribe.self) else {
            return replyError(connection, requestID, .invalidParams("events/subscribe takes a filter object and an optional after."))
        }
        connection.runningCalls += 1
        Task {
            defer { connection.runningCalls -= 1 }
            guard let grant = await grantForCall(from: connection, identity, requestID: requestID), connections[connection.id] != nil else { return }
            guard grant.scopes.watchEvents else {
                return replyError(connection, requestID, Self.noGrantError("This client's grant does not include Watch Browser Events. Revoke it in Settings \u{25B8} AI \u{25B8} Agents and allow it again with that scope."))
            }
            let match: AgentEventMatch
            switch AgentEventMatch.make(subscribe.filter, spaces: host.spaces(in: grant.personaID)) {
            case .success(let made): match = made
            case .failure(let error): return replyError(connection, requestID, error)
            }
            let events = outsidePrograms.subscriptions[connection.id] ?? AgentConnectionEvents(grantID: grant.id)
            guard events.grantID == grant.id, !events.isFull else {
                return replyError(connection, requestID, AgentRPCError(code: AgentControlErrorCode.busy, message: "A connection holds at most \(AgentLimits.subscriptionsPerConnection) subscriptions."))
            }
            outsidePrograms.subscriptions[connection.id] = events
            let id = events.add(match)
            if usedThisLaunch.insert(grant.id).inserted { record(.firstUse, grant: grant) }
            touch(grant)
            let buffer = outsidePrograms.buffer(for: grant.id)
            reply(connection, requestID, Self.json(AgentEventSubscription(subscription: id, sequence: buffer.lastSequence)))
            guard let after = subscribe.after else { return }
            for buffered in buffer.events(after: after, matching: { match.matches($0.event, allowsAI: dependencies.allowsAI) }) {
                events.enqueue(buffered.view, for: id)
            }
            scheduleFlush(of: connection.id, events)
        }
    }

    private func unsubscribeEvents(_ params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard case .number(let number)? = params?["subscription"], let id = Int(exactly: number) else {
            return replyError(connection, requestID, .invalidParams("events/unsubscribe takes the subscription's number."))
        }
        reply(connection, requestID, ["unsubscribed": .bool(outsidePrograms.subscriptions[connection.id]?.remove(id) ?? false)])
    }

    /// Writes the connection's queued events after the current event has reached every subscriber, after saying how many each subscription dropped.
    private func scheduleFlush(of connectionID: UUID, _ events: AgentConnectionEvents) {
        guard !events.flushScheduled else { return }
        events.flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let events = self.outsidePrograms.subscriptions[connectionID] else { return }
                events.flushScheduled = false
                for (subscription, count) in events.dropped.sorted(by: { $0.key < $1.key }) {
                    self.endpoint?.send(.notification(method: AgentControlMethod.eventsDroppedNotification, params: ["subscription": .number(Double(subscription)), "count": .number(Double(count))]), to: connectionID)
                }
                events.dropped = [:]
                let queued = events.queue
                events.queue = []
                for item in queued {
                    self.endpoint?.send(.notification(method: AgentControlMethod.eventNotification, params: ["subscription": .number(Double(item.subscription)), "event": item.view]), to: connectionID)
                }
            }
        }
    }

    /// A grant ended: its events go, and the hooks its program added pause unless the identity has another grant in force.
    private func programGrantDidEnd(_ grantID: UUID) {
        outsidePrograms.grantDidEnd(grantID)
        grantsInForceDidChange()
    }

    /// Tells the hook registry which identities have a grant in force, once `agent.json` was checked, so that the hooks of a program whose grant ended pause with `grantEnded`.
    func grantsInForceDidChange() {
        guard canChangeSettings, let hookRegistrar else { return }
        hookRegistrar.grantsDidChange(inForce: Set(grants.filter(grantsInForce()).map(\.client.key)))
    }

    /// `hooks/list`, `hooks/add`, and `hooks/remove`, each for a client with a grant of any level, which the first asks for as a tool call does. `hooks/add` checks the proposal against the caps of hooks from outside programs, says it waits for the user, and answers once the user answered the registry's proposal sheet.
    private func hookCall(_ method: String, _ params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard let identity = connection.identity else { return }
        guard connection.runningCalls < AgentLimits.callsPerConnection else {
            return replyError(connection, requestID, AgentRPCError(code: AgentControlErrorCode.busy, message: "This connection already runs \(AgentLimits.callsPerConnection) calls."))
        }
        // The connection's close cancels the call, which closes an open proposal sheet unanswered.
        let running = connection.startCall(requestID)
        running.task = Task {
            defer { connection.endCall(running) }
            guard let grant = await grantForCall(from: connection, identity, requestID: requestID, call: running), connections[connection.id] != nil, !running.isCancelled else { return }
            guard let registrar = hookRegistrar else {
                return replyError(connection, requestID, .internalError("Arch cannot reach its hooks now."))
            }
            touch(grant)
            switch method {
            case AgentControlMethod.hooksList:
                var hooks = registrar.hooks(addedBy: identity.key)
                // A last run's time would tell when the user visited the hook's sites, which only Watch Browser Events shows.
                if !grant.scopes.watchEvents { hooks = hooks.map { var hook = $0; hook.lastRun = nil; return hook } }
                reply(connection, requestID, Self.json(AgentHookListing(hooks: hooks)))
            case AgentControlMethod.hooksRemove:
                guard let text = params?["hook"]?.stringValue, let id = UUID(uuidString: text) else {
                    return replyError(connection, requestID, .invalidParams("hooks/remove takes the hook's ID, as hooks list shows it."))
                }
                reply(connection, requestID, ["removed": .bool(registrar.remove(id, addedBy: identity.key))])
            default:
                guard let add = try? params?.decode(as: AgentHookAdd.self) else {
                    return replyError(connection, requestID, .invalidParams("hooks/add takes the hook's name, event, filter, script, permissions, and agent options."))
                }
                let answer: AgentHookAddResult
                do {
                    let proposal = try AgentHookProposal.make(add, grant: grant, spaces: host.spaces(in: grant.personaID))
                    endpoint?.send(.notification(method: AgentControlMethod.progressNotification, params: ["call": requestID.json, "message": "Waiting for your approval in Arch\u{2026}"]), to: connection.id)
                    switch await registrar.propose(proposal, from: identity, grant: grant) {
                    case .added(let id): answer = AgentHookAddResult(status: .added, hook: id)
                    case .declined(let reason): answer = AgentHookAddResult(status: .declined, message: reason)
                    case .refused(let reason): answer = AgentHookAddResult(status: .refused, message: reason)
                    }
                } catch {
                    answer = AgentHookAddResult(status: .refused, message: (error as? AgentHookRefusal)?.message ?? "\(error)")
                }
                guard connections[connection.id] != nil, !running.isCancelled else { return }
                reply(connection, requestID, Self.json(answer))
            }
        }
    }

    /// An outside client's call: `watch_events` reads the grant's event buffer here, with the tool host's argument check and daily count, and every other tool, `rename_tab` with P19's card among them, runs in the tool host.
    private func runOutsideCall(_ call: AgentToolCall, for grant: AgentGrant, connectionID: UUID, callID: Int?) async -> AgentToolHost.Outcome {
        guard call.name == AgentToolCatalog.watchEvents.name else {
            return await toolHost(connectionID: connectionID, callID: callID).run(call, for: grant, state: state(for: grant))
        }
        if let problem = AgentToolHost.problem(with: call.arguments, for: AgentToolCatalog.watchEvents) { return AgentToolHost.error("invalidArguments", problem) }
        guard grant.scopes.watchEvents else {
            return AgentToolHost.Outcome(result: AgentToolResult(status: .refused, code: "eventsScope", text: "This client's grant does not include Watch Browser Events, so it cannot watch events."))
        }
        guard state(for: grant).countCall(at: dependencies.now()) else {
            return AgentToolHost.error("limitReached", "This client made \(AgentToolHost.number(AgentLimits.toolCallsPerGrantPerDay)) tool calls today, the most for a day. Its calls work again tomorrow.")
        }
        return await AgentToolHost.watchEvents(call.arguments, buffer: outsidePrograms.buffer(for: grant.id))
    }
}

// MARK: - Outside programs' runs

extension AgentService {
    /// `agent/run` from an outside client with Start Agent Tasks, asked for a grant first as a tool call is: one run under `agentRun` with `AgentRunGrant.forClient(_:)`, recorded with its model and outcome in the activity log, whose tool calls the runner records too. The client's connection closing cancels it.
    private func runAgent(_ params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard let identity = connection.identity else { return }
        guard connection.runningCalls < AgentLimits.callsPerConnection else {
            return replyError(connection, requestID, AgentRPCError(code: AgentControlErrorCode.busy, message: "This connection already runs \(AgentLimits.callsPerConnection) calls."))
        }
        guard case .object(let fields)? = params else { return replyError(connection, requestID, .invalidParams("agent/run takes the run's options as one object.")) }
        let running = connection.startCall(requestID)
        running.task = Task {
            defer { connection.endCall(running) }
            guard let grant = await grantForCall(from: connection, identity, requestID: requestID, call: running), connections[connection.id] != nil, !running.isCancelled else { return }
            guard grant.scopes.startTasks else {
                return replyError(connection, requestID, Self.noGrantError("This client's grant does not include Start Agent Tasks. Revoke it in Settings \u{25B8} AI \u{25B8} Agents and allow it again with that scope."))
            }
            if usedThisLaunch.insert(grant.id).inserted { record(.firstUse, grant: grant) }
            touch(grant)
            endpoint?.send(.notification(method: AgentControlMethod.progressNotification, params: ["call": requestID.json, "message": "The agent runs in Arch\u{2026}"]), to: connection.id)
            let runID = UUID()
            let result = await outsideRun(fields, for: grant, identity: identity, run: runID)
            activity.record(AgentActivityEntry(date: dependencies.now(), event: .agentRun, grantID: grant.id, clientName: identity.displayName, personaID: grant.personaID,
                                               decision: result.status == .refused ? .refused : .auto, rule: result.status == .refused ? result.code : nil, outcome: result.status.rawValue,
                                               model: result.model.map { "\($0.provider.rawValue)/\($0.model)" }, runID: runID))
            guard !running.isCancelled, connections[connection.id] != nil else { return }
            reply(connection, requestID, clientJSON(of: result, for: grant))
        }
    }

    /// An outside run's result as its client reads it: each renamed tab by the client's handle, never by Arch's identifier.
    func clientJSON(of result: AgentRunResult, for grant: AgentGrant) -> AgentJSON {
        let state = state(for: grant)
        return Self.json(of: result) { state.handles.tabs.handle(for: $0) }
    }

    /// A run's result as its caller reads it: each renamed tab by the caller's handle for it, never by Arch's identifier, and a tab the caller has no handle for left out.
    static func json(of result: AgentRunResult, handle: (UUID) -> String?) -> AgentJSON {
        guard case .object(var fields) = json(result) else { return json(result) }
        fields["actions"] = .array(result.actions.compactMap { action in
            switch action {
            case .renamedTab(let tab, let name): return handle(tab).map { ["renamedTab": ["tab": .string($0), "name": .string(name)]] }
            }
        })
        return .object(fields)
    }

    /// `agent/run` on a shell hook run's connection: the run's handler runs it under the hook's grant, feature, and run tabs, or refuses it with -32601 when the hook may start no agent runs, and the answer names each renamed tab by its run handle, as `arch-cli rename` inside the run names it. The run's end cancels it.
    private func runShellHookAgent(_ params: AgentJSON?, on connection: ClientConnection, requestID: AgentRPCID) {
        guard let id = connection.sessionID, let run = shellHookRuns[id], let agentRun = run.agentRun else {
            return replyError(connection, requestID, .methodNotFound(AgentControlMethod.agentRun))
        }
        guard connection.runningCalls < AgentLimits.callsPerConnection else {
            return replyError(connection, requestID, AgentRPCError(code: AgentControlErrorCode.busy, message: "This connection already runs \(AgentLimits.callsPerConnection) calls."))
        }
        guard case .object(let fields)? = params else { return replyError(connection, requestID, .invalidParams("agent/run takes the run's options as one object.")) }
        let running = connection.startCall(requestID)
        running.task = Task {
            defer { connection.endCall(running) }
            let result = await agentRun(fields)
            guard !running.isCancelled, connections[connection.id] != nil else { return }
            reply(connection, requestID, Self.json(of: result) { run.handles[$0] })
        }
    }

    /// The run of an outside client's options: its tabs by the client's handles, or else every agent tab of the client and tab shared with it, the Standard tier, Keep Activity Only, tab access `title` with `rename_tab` or `page` with the read tools too, and the program's label. The shared tabs the user let the client rename on P19's card rename in the run too.
    private func outsideRun(_ given: [String: AgentJSON], for grant: AgentGrant, identity: AgentClientIdentity, run: UUID) async -> AgentRunResult {
        func refused(_ code: String, _ message: String) -> AgentRunResult { AgentRunResult(status: .refused, code: code, message: message) }
        var fields = given
        let state = state(for: grant)
        let own = host.agentTabs(of: grant.id)
        let shared = host.tabs(withIDs: Set(state.handles.sharedTabIDs)).filter { $0.agentOwnerID == nil }
        let reachable = own + shared
        var ids = reachable.map(\.id)
        if let value = fields.removeValue(forKey: "tabs") {
            guard case .array(let items) = value else { return refused("invalidArguments", "tabs takes a list of this client's tab handles, such as [\"t1\"].") }
            ids = []
            for item in items {
                guard let handle = item.stringValue, let id = state.handles.tabs.id(for: handle) else { return refused("tabNotFound", "This client has no tab \(item.stringValue ?? "").") }
                guard reachable.contains(where: { $0.id == id }) else { return refused(AgentRule.p17.rawValue, AgentPolicy.entry(.p17).sentence) }
                if !ids.contains(id) { ids.append(id) }
            }
        }
        guard !ids.isEmpty else { return refused("noTab", "This client has no agent tab or shared tab to run on. Open one with open_tab first.") }
        let page = fields["tabAccess"] == .string(AgentRunTabAccess.page.rawValue)
        fields["tabAccess"] = fields["tabAccess"] ?? .string(AgentRunTabAccess.title.rawValue)
        fields["tools"] = fields["tools"] ?? .array((page ? [AgentToolCatalog.renameTab.name, "read_text", "snapshot"] : [AgentToolCatalog.renameTab.name]).map(AgentJSON.string))
        fields["record"] = fields["record"] ?? .string(AgentRunRecord.activity.rawValue)
        fields["model"] = fields["model"] ?? ["tier": .string(AIModelTier.standard.rawValue)]
        guard let options = try? AgentJSON.object(fields).decode(as: AgentRunOptions.self) else {
            return refused("invalidArguments", "agent/run takes prompt, and optionally model, tabAccess, tools, record, limits, tabs, and dryRun, as arch.agent.run does.")
        }
        var documents: [UUID: URL] = [:]
        var documentIDs: [UUID: UUID] = [:]
        for tab in reachable where ids.contains(tab.id) {
            guard let url = tab.url else { continue }
            documents[tab.id] = url
            documentIDs[tab.id] = tab.documentID
        }
        var request = AgentRunRequest(options: options, tabs: ids, allowedTabs: Set(reachable.map(\.id)), documents: documents, documentIDs: documentIDs, knownProviders: nil,
                                      origin: .outsideClient(grant: grant.id, run: run), promptSource: .program(name: identity.displayName), feature: .agentRun, grant: .forClient(grant))
        request.sharedTabs = Set(shared.map(\.id)).intersection(ids)
        request.renamingSharedTabs = state.handles.renamingSharedTabIDs.intersection(request.sharedTabs)
        let naming = host as? AgentTabNaming
        return await runs.run(request, personaID: grant.personaID) { id, name, document, applying in
            naming?.suggestName(name, forTab: id, showing: document, byGrant: grant.id, applying: applying) ?? false
        }
    }
}
