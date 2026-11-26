// Coordinates the signed-in user's private sync database. The account check must succeed
// and the user's toggle must be on before the controller starts a sync engine.
import Browsing
import CloudKit
import Combine
import Foundation

/// Coordinates account availability, local sidebar saves, and CloudKit sync engine events.
@MainActor public final class SyncController: ObservableObject {
    public static let enabledKey = "ARCHSyncEnabled"
    @Published public private(set) var availability: SyncAvailability.Status = .unavailable(.temporarilyUnavailable)
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var isDeletingCloudData = false
    @Published public private(set) var offReason: SyncOffReason?
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastSync: Date?
    @Published public private(set) var hasCheckedAvailability = false
    @Published public private(set) var isCheckingAvailability = false
    /// Platform notification registration follows the engine lifetime. Persona deletion
    /// messaging follows the saved preference, including edits queued while temporarily offline.
    public var onRunningChange: ((Bool) -> Void)?
    public var onEnabledChange: ((Bool) -> Void)?
    public let settings: SyncedSettings

    private let sidebar: any SyncedSidebar
    private let defaults: UserDefaults
    private let url: URL
    private let check: () async -> SyncAvailability.Status
    private let factory: SyncEngineFactory
    private let now: () -> Date
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var accountContainer: (() -> AnyObject?)?
    private var requestedAccountCheck = false
    private var checkNumber = 0
    private var database: SyncDatabase?
    private var engine: (any SyncEngineClient)? {
        didSet {
            if (oldValue == nil) != (engine == nil) { onRunningChange?(engine != nil) }
        }
    }
    private var delegate: Delegate?
    private var mirror = SyncMirror()
    private var durableSidebar: SidebarSyncState?
    private var refusedSaves: [String: SyncRecord] = [:]
    private static let offReasonKey = "ARCHSyncOffReason"
    private static let discardStateKey = "ARCHSyncDiscardPreviousState"
    /// Set while a confirmed Delete iCloud Data waits for the server, so that a launch after a quit in that time can say the data is still there.
    private static let deletionRequestedKey = "ARCHSyncDeletionRequested"
    /// Set while the controller applies incoming changes or builds a batch of outgoing records (`docs/sync.md`, Crash-loop guard).
    static let applyingKey = "ARCHSyncApplyingChanges"
    /// The key marks the time of an apply or a batch build, not a crash, so the message names only the quit.
    static let interruptedApplyMessage = localized("Sync turned off because Arch quit before it finished syncing with iCloud. Turn it on to try again.")
    private var guardHolds = 0
    private var quitBeforeDeletion: (any SyncEngineClient)?
    private var first = false
    private var fetching = false
    private var applying = false
    private var fetched: [String: CKRecord] = [:]
    private var deleted: [String: SyncRecordType] = [:]
    private var deletedNames = Set<String>()
    private var unknown = Set<String>()
    private var missingZone = false
    private var awaitingZoneSave = false
    private var pendingState: Data?
    private var fetchTask: Task<Void, Never>?
    private var needsRecoveryFetch = false
    private var deletionSendInFlight = false
    /// The unapplied mirror records that this launch's first fetch applies as if fetched (`SyncMirror.unapplied`).
    private var reapplying = Set<String>()

    public convenience init(sidebar: any SyncedSidebar, directory: URL, defaults: UserDefaults = .standard) {
        let availability = SyncAvailability()
        self.init(sidebar: sidebar, directory: directory, defaults: defaults, check: availability.check,
                  factory: { CloudKitSyncEngine(database: $0, stateSerialization: $1, delegate: $2) })
        if let entitlement = availability.entitledDatabase() {
            accountContainer = { CKContainer(identifier: entitlement.containerIdentifier) }
        } else {
            self.availability = .unavailable(.notSignedForICloud)
            hasCheckedAvailability = true
        }
    }

    init(sidebar: any SyncedSidebar, directory: URL, defaults: UserDefaults,
         notifications: NotificationCenter = .default, check: @escaping () async -> SyncAvailability.Status,
         factory: @escaping SyncEngineFactory, now: @escaping () -> Date = Date.init) {
        self.sidebar = sidebar
        self.defaults = defaults
        self.notifications = notifications
        self.check = check
        self.factory = factory
        self.now = now
        url = directory.appendingPathComponent(SyncMirror.fileName)
        settings = SyncedSettings(defaults: defaults)
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        offReason = defaults.string(forKey: Self.offReasonKey).flatMap(SyncOffReason.init(rawValue:))
        if defaults.bool(forKey: Self.applyingKey) {
            // Settings ▸ Sync shows the reason at every launch until sync is turned on again.
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            lastError = Self.interruptedApplyMessage
        }
        observers.append(notifications.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
    }

    /// Only while an engine runs, so that a session save with sync off builds no projection.
    private func observeSidebarSaves() {
        sidebar.onSidebarSyncSave = { [weak self] state in self?.sidebarSaved(state) }
    }

    // The account notification's object is the entitled container. Retain it as long as the observer.
    func observeAccountChanges(of container: AnyObject) {
        observers.append(notifications.addObserver(forName: .CKAccountChanged, object: container, queue: .main) { [weak self, container] _ in
            _ = container
            Task { @MainActor [weak self] in await self?.refresh() }
        })
    }
    deinit { for observer in observers { notifications.removeObserver(observer) } }

    /// Saves the user's sync choice, checking availability when turning it on and stopping the engine when turning it off.
    public func setEnabled(_ enabled: Bool) async {
        guard !isDeletingCloudData else { return }
        if guardHolds == 0, defaults.bool(forKey: Self.applyingKey) {
            // The user's choice ends the hold: turning sync on applies the changes again.
            defaults.removeObject(forKey: Self.applyingKey)
            lastError = nil
        }
        if enabled { recordOffReason(nil) }
        updateEnabled(enabled)
        if enabled { await refresh() } else {
            checkNumber += 1
            isCheckingAvailability = false
            await stop()
        }
    }

    /// Called after the user confirms the deletion. Keep the previous file until the server
    /// confirms the zone is gone. Interrupted or refused requests can be retried explicitly.
    public func deleteCloudData() async {
        guard let engine, isEnabled, !isDeletingCloudData else { return }
        isDeletingCloudData = true
        lastError = nil
        defaults.set(true, forKey: Self.deletionRequestedKey)
        engine.add([.deleteZone])
        await sendZoneDeletion(on: engine)
    }

    /// Sends a confirmed zone deletion and resumes sync if the request fails.
    private func sendZoneDeletion(on engine: any SyncEngineClient) async {
        guard !deletionSendInFlight else { return }
        lastError = nil
        deletionSendInFlight = true
        defer { if self.engine === engine { deletionSendInFlight = false } }
        do { try await guarded { try await engine.sendChanges() } }
        catch {
            if self.engine === engine, !engine.pendingChanges.contains(.deleteZone) {
                lastError = localized("Arch could not delete its iCloud data.")
            }
        }
        guard self.engine === engine, isDeletingCloudData else { return }
        if engine.pendingChanges.contains(.deleteZone), lastError == nil {
            // CloudKit owns retries for offline and temporarily unavailable accounts. Keep the
            // live request scoped to this engine. A relaunch starts from the pre-deletion file.
            lastError = localized("Arch is waiting to delete its iCloud data.")
            return
        }
        await resumeAfterDeleteFailure(on: engine,
            message: lastError ?? localized("Arch could not delete its iCloud data. Try again when connected."))
    }

    /// The engine dropped what it fetched while the deletion waited but kept its change token past it, so a new engine starts from `sync.json`, which kept the state from before the deletion, and fetches those changes again.
    private func resumeAfterDeleteFailure(on engine: any SyncEngineClient, message: String) async {
        guard self.engine === engine else { return }
        defaults.removeObject(forKey: Self.deletionRequestedKey)
        await stop()
        await refresh()
        if self.engine != nil { lastError = message }
    }

    /// Launch and activation can read the local toggle and entitlements. The first account
    /// request comes from an explicit opt-in or an existing enabled preference.
    public func refreshIfRequested() async {
        guard isEnabled || requestedAccountCheck else { return }
        await refresh()
    }

    /// Refresh after an explicit account request or the observed container's account change.
    public func refresh() async {
        requestedAccountCheck = true
        if let makeContainer = accountContainer {
            accountContainer = nil
            if let container = makeContainer() { observeAccountChanges(of: container) }
        }
        isCheckingAvailability = true
        checkNumber += 1
        let number = checkNumber
        let result = await check()
        guard number == checkNumber else { return }
        isCheckingAvailability = false
        hasCheckedAvailability = true
        availability = result
        if case .unavailable(.noAccount) = result, isEnabled, engine != nil || FileManager.default.fileExists(atPath: url.path) {
            // The availability notification can arrive before the engine's sign-out event.
            // Invalidate its token now so a subsequent account cannot resume it. Before any
            // sync there is no token, and the opt-in waits for an account as for the other reasons.
            disableAfterLoss(.accountChanged)
            return
        }
        guard isEnabled, case .available(let target) = result else { await stop(); return }
        if database != target || engine == nil {
            await stop()
            guard number == checkNumber, isEnabled else { return }
            database = target
            do {
                try discardPreviousStateIfNeeded()
            } catch {
                lastError = localized("The previous sync state could not be removed.")
                return
            }
            // A recovered or replacement local session says nothing about deletions. Its old
            // mirror could turn every missing row into an outgoing delete. A nil token and
            // first-sync merge restore the complete zone while preserving local-only additions.
            mirror = sidebar.needsFullSidebarSync ? SyncMirror() : SyncMirror.read(from: url, database: target)
            reapplying = mirror.unapplied.filter { mirror.records[$0] != nil }
            for name in reapplying { fetched[name] = mirror.records[name] }
            first = mirror.isEmpty
            fetching = true
            lastError = nil
            let delegate = Delegate(self)
            self.delegate = delegate
            engine = factory(target, mirror.engineState, delegate)
            observeSidebarSaves()
            if defaults.bool(forKey: Self.deletionRequestedKey) {
                // The deletion never reached the server: `sync.json` kept its state from before it.
                defaults.removeObject(forKey: Self.deletionRequestedKey)
                quitBeforeDeletion = engine
            }
        }
        if isDeletingCloudData {
            if let engine { await sendZoneDeletion(on: engine) }
            return
        }
        refusedSaves.removeAll()
        if awaitingZoneSave { engine?.add([.saveZone]) }
        await requestFetch()
        if let quit = quitBeforeDeletion, quit === engine {
            quitBeforeDeletion = nil
            lastError = localized("Arch quit before it deleted its iCloud data. Delete it again to remove it.")
        }
    }

    /// Detaches and stops the active engine.
    private func stop() async {
        await detach()?.stop()
    }

    /// Clears the active engine, fetch, mirror, and pending state before a stop or restart.
    private func detach() -> (any SyncEngineClient)? {
        let previous = engine
        sidebar.onSidebarSyncSave = nil
        quitBeforeDeletion = nil
        engine = nil
        delegate = nil
        isDeletingCloudData = false
        deletionSendInFlight = false
        database = nil
        needsRecoveryFetch = false
        reapplying.removeAll()
        fetchTask?.cancel()
        fetchTask = nil
        first = false
        fetching = false
        applying = false
        fetched.removeAll()
        deleted.removeAll()
        deletedNames.removeAll()
        unknown.removeAll()
        missingZone = false
        awaitingZoneSave = false
        pendingState = nil
        refusedSaves.removeAll()
        durableSidebar = nil
        mirror = SyncMirror()
        return previous
    }

    /// Fetches changes once per active request and repeats when recovery needs another fetch.
    private func requestFetch() async {
        if let fetchTask { await fetchTask.value; return }
        guard let engine else { return }
        fetching = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                needsRecoveryFetch = false
                do { try await guarded { try await engine.fetchChanges() } }
                catch {
                    if self.engine === engine, fetching { lastError = localized("The sync fetch did not finish.") }
                }
            } while self.engine === engine && needsRecoveryFetch
            if self.engine === engine { fetchTask = nil }
        }
        fetchTask = task
        await task.value
    }

    var canSendRecords: Bool { engine != nil && !first && !fetching && !applying && !isDeletingCloudData }
    /// Builds a pending record only after the first fetch and outside an apply or deletion.
    func record(toSave name: String) -> CKRecord? {
        guard canSendRecords, let save = mirror.pendingSaves.first(where: { $0.recordName == name }) else { return nil }
        let base = mirror.records[name]
        guard base.map({ $0.recordType == save.recordType.rawValue }) ?? true else { return nil }
        return SyncCloudKitRecords.ckRecord(from: save, base: base)
    }

    /// Holds the crash-loop guard: the first hold sets `applyingKey` and the last release removes it, so an apply and a batch build that overlap write it once and leave it set until both end.
    private func holdGuard() {
        if guardHolds == 0 { defaults.set(true, forKey: Self.applyingKey) }
        guardHolds += 1
    }

    private func releaseGuard() {
        guard guardHolds > 0 else { return }
        guardHolds -= 1
        if guardHolds == 0 { defaults.removeObject(forKey: Self.applyingKey) }
    }

    /// Runs one fetch or send that Arch asks the engine for under the crash-loop guard, so that a crash inside the engine's call, as CloudKit's own check stops the app, keeps sync off at the next launch instead of stopping the app at every launch.
    private func guarded(_ call: () async throws -> Void) async rethrows {
        holdGuard()
        defer { releaseGuard() }
        try await call()
    }

    /// A quit that ends normally is no crash, so it clears the crash-loop guard that a fetch, a send, an apply, or a batch build still holds, and the next launch keeps sync on.
    public func applicationWillTerminate() {
        guardHolds = 0
        defaults.removeObject(forKey: Self.applyingKey)
    }

    private var bases: [SyncRecord] { mirror.records.values.compactMap(SyncCloudKitRecords.syncRecord(from:)) }
    /// Compares a newly saved sidebar and checkpoints changes when the engine can send them.
    private func sidebarSaved(_ state: SidebarSyncState) {
        guard engine != nil, !applying else { return }
        durableSidebar = state
        do {
            try compareSidebar(state)
            if canSendRecords { persist() }
        } catch { lastError = localized("The saved sidebar could not be compared.") }
    }

    func settingsChanged() {
        let keys = settings.changedKeys()
        guard engine != nil, !keys.isEmpty, !applying else { return }
        compareSettings()
        if canSendRecords { persist() }
    }

    /// Builds sidebar changes against the mirror while excluding records this build holds out.
    private func compareSidebar(_ state: SidebarSyncState, publish: Bool? = nil) throws {
        let date = now()
        let records = try SidebarRecords.records(from: state, foundAt: date)
        let base = bases
        // What this build cannot apply stays on the server as another build wrote it.
        let held = IncomingSidebarRecords.heldOut(server: base, local: records)
        let scope = { (record: SyncRecord) in record.recordType != .setting && !held.contains(record.recordName) && (state.canSyncSiteRules || record.recordType != .siteRule) }
        let changes = SyncDiff.changes(local: records.filter(scope), scope: scope, mirror: base, pending: mirror.pendingSaves, foundAt: date)
        reconcile(changes, publish: publish ?? canSendRecords, includes: { $0.recordType != .setting })
    }

    /// Builds changed setting records against the mirror and pending saves.
    private func compareSettings(publish: Bool? = nil) {
        let comparison = settings.comparison(mirror: bases, pending: mirror.pendingSaves)
        let changes = SyncDiff.changes(local: comparison.records, scope: comparison.contains, mirror: bases, pending: mirror.pendingSaves, foundAt: now())
        reconcile(changes, publish: publish ?? canSendRecords, includes: { $0.recordType == .setting })
    }

    /// Replaces pending changes for one record scope and updates the engine's change queue.
    private func reconcile(_ changes: SyncChanges, publish: Bool, includes: (SyncRecord) -> Bool) {
        guard let engine else { return }
        let old = mirror.pendingSaves.filter(includes)
        let owned = Set((old + bases.filter(includes) + changes.saves).map(\.recordName)).union(changes.deletions)
        mirror.pendingSaves.removeAll(where: includes)
        mirror.pendingSaves.append(contentsOf: changes.saves)
        guard publish else { return }
        let wanted = changes.saves.filter { refusedSaves[$0.recordName] != $0 }.map { SyncPendingChange.saveRecord($0.recordName) } + changes.deletions.map(SyncPendingChange.deleteRecord)
        let current = engine.pendingChanges.filter {
            switch $0 {
            case .saveRecord(let key), .deleteRecord(let key): return owned.contains(key)
            case .saveZone, .deleteZone: return false
            }
        }
        let wantedSet = Set(wanted), existing = Set(current)
        let remove = current.filter { !wantedSet.contains($0) }, add = wanted.filter { !existing.contains($0) }
        if !remove.isEmpty { engine.remove(remove) }
        if !add.isEmpty { engine.add(add) }
    }

    /// Handles fetch, save, zone, and account events from the active sync engine.
    private func handle(_ event: SyncEvent) {
        guard engine != nil else { return }
        if isDeletingCloudData {
            switch event {
            case .accountChange, .zoneDeleted, .sentZoneChanges: break
            default: return
            }
        }
        switch event {
        case .fetchStarted: fetching = true
        case .stateUpdate(let state):
            pendingState = state
            if canSendRecords { persist() }
        case .fetchedChanges(let page):
            fetching = true
            buffer(page)
        case .fetchEnded(let error):
            // The zone fetch itself can report a missing zone, before any record save has run.
            if error == .zoneNotFound {
                if mirror.records.isEmpty {
                    finishFetch()
                } else { disableAfterLoss(.zoneDeleted) }
                return
            }
            if let error {
                lastError = localized("The sync fetch did not finish (\(error.rawValue)).")
                return
            }
            if missingZone { disableAfterLoss(.zoneDeleted); return }
            finishFetch()
        case .sentChanges(let sent): didSend(sent)
        case .sentZoneChanges(let sent):
            if isDeletingCloudData {
                if sent.deletedZone || sent.failedDelete == .zoneNotFound {
                    disableAfterLoss(.zoneDeleted)
                } else if let refusal = sent.failedDelete {
                    let message = localized("Arch could not delete its iCloud data (\(refusal.rawValue)).")
                    lastError = message
                    if let engine {
                        // A retry can finish after the original send operation already returned.
                        Task { @MainActor [weak self] in
                            guard let self, self.engine === engine, isDeletingCloudData else { return }
                            await resumeAfterDeleteFailure(on: engine, message: message)
                        }
                    }
                }
                return
            }
            if sent.savedZone {
                awaitingZoneSave = false
                if let engine { flushHeldChanges(on: engine) }
            }
            if sent.failedSave != nil { awaitingZoneSave = true }
            if let code = sent.failedSave ?? sent.failedDelete { lastError = localized("The sync zone change failed (\(code.rawValue)).") }
        case .accountChange(let account):
            if account == .signIn {
                if isEnabled && !isDeletingCloudData && fetchTask == nil {
                    let active = engine
                    Task { @MainActor [weak self] in
                        guard let self, self.engine === active else { return }
                        await refresh()
                    }
                }
            } else {
                disableAfterLoss(.accountChanged)
                let generation = checkNumber
                Task { @MainActor [weak self] in
                    guard let self, checkNumber == generation else { return }
                    await refresh()
                }
            }
        case .zoneDeleted(let id, let reason):
            guard id == SyncCloudKitRecords.zoneID else { return }
            if reason == .encryptedDataReset {
                fetched.removeAll(); deleted.removeAll(); deletedNames.removeAll()
                mirror.records.removeAll()
                unknown.removeAll(); missingZone = false; first = true
            } else { disableAfterLoss(.zoneDeleted) }
        }
    }

    /// Accumulates fetched records and tombstones until the fetch ends.
    private func buffer(_ page: SyncFetchedChanges) {
        for row in page.records where SyncCloudKitRecords.isInZone(row.recordID) {
            let key = row.recordID.recordName
            fetched[key] = row
            deleted[key] = nil
            deletedNames.remove(key)
        }
        for removal in page.deletions where SyncCloudKitRecords.isInZone(removal.recordID) {
            let key = removal.recordID.recordName
            fetched[key] = nil
            deletedNames.insert(key)
            deleted[key] = SyncRecordType(rawValue: removal.recordType)
        }
    }

    private func updateEnabled(_ value: Bool) {
        guard isEnabled != value else { return }
        isEnabled = value
        defaults.set(value, forKey: Self.enabledKey)
        onEnabledChange?(value)
    }

    private func recordOffReason(_ reason: SyncOffReason?) {
        offReason = reason
        defaults.set(reason?.rawValue, forKey: Self.offReasonKey)
    }

    /// Turns sync off and discards prior state after account or zone loss.
    private func disableAfterLoss(_ reason: SyncOffReason) {
        recordOffReason(reason)
        defaults.removeObject(forKey: Self.deletionRequestedKey)
        lastError = nil
        lastSync = nil
        isCheckingAvailability = false
        updateEnabled(false)
        checkNumber += 1
        let old = detach()
        defaults.set(true, forKey: Self.discardStateKey)
        do { try discardPreviousStateIfNeeded() }
        catch { lastError = localized("The previous sync state could not be removed.") }
        Task { await old?.stop() }
    }

    private func discardPreviousStateIfNeeded() throws {
        guard defaults.bool(forKey: Self.discardStateKey) else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        defaults.removeObject(forKey: Self.discardStateKey)
    }

    /// Applies a complete fetch, saves the sidebar and mirror, then releases pending changes.
    private func finishFetch() {
        guard let engine else { return }
        // Set before the settings check below, so that a change notification this write delivers at once counts as one that came before the fetch ended.
        holdGuard()
        defer { releaseGuard() }
        applying = true
        do {
            let date = now()
            let base = bases
            // A defaults notification can still be waiting on the main queue.
            if !settings.changedKeys().isEmpty { compareSettings(publish: false) }
            let local = try SidebarRecords.records(from: sidebar.sidebarSyncState, foundAt: date)
            // An earlier completed fetch may have delivered a rule before its destination.
            // Retry it when later records arrive, without waiting for another launch.
            for name in mirror.unapplied where fetched[name] == nil && !deletedNames.contains(name) {
                guard let record = mirror.records[name], record.recordType == SyncRecordType.siteRule.rawValue else { continue }
                fetched[name] = record
                reapplying.insert(name)
            }
            let server = fetched.values.compactMap(SyncCloudKitRecords.syncRecord(from:)).filter { sidebar.sidebarSyncState.canSyncSiteRules || $0.recordType != .siteRule }
            if first {
                let comparison = settings.comparison(mirror: base, pending: mirror.pendingSaves)
                try applyFirst(local: local + comparison.records, server: server, date: date)
            } else {
                try applyFetched(local: local, server: server, base: base, date: date)
            }
            try sidebar.saveNow().get()
            durableSidebar = sidebar.sidebarSyncState
            // The synchronous write supersedes every queued callback from earlier session writes.
            observeSidebarSaves()
            for key in unknown where fetched[key] == nil && !deletedNames.contains(key) { mirror.records[key] = nil }
            unknown.removeAll()
            for key in deletedNames {
                mirror.records[key] = nil
                mirror.pendingSaves.removeAll { $0.recordName == key }
                engine.remove([.saveRecord(key), .deleteRecord(key)])
            }
            for (key, row) in fetched { mirror.records[key] = row }
            mirror.unapplied = IncomingSidebarRecords.heldOut(server: bases, local: try SidebarRecords.records(from: sidebar.sidebarSyncState, foundAt: date))
                .union(mirror.records.compactMap { entry in
                    let unsupported = SyncCloudKitRecords.syncRecord(from: entry.value) == nil
                    let unreadableRules = !sidebar.sidebarSyncState.canSyncSiteRules && entry.value.recordType == SyncRecordType.siteRule.rawValue
                    return unsupported || unreadableRules ? entry.key : nil
                })
            reapplying.removeAll()
            if mirror.records.isEmpty {
                awaitingZoneSave = true
                engine.add([.saveZone])
            } else if !fetched.isEmpty, awaitingZoneSave {
                // A fetched record proves another device already created the zone.
                awaitingZoneSave = false
                engine.remove([.saveZone])
            }
            try compareSidebar(sidebar.sidebarSyncState, publish: true)
            compareSettings(publish: true)
            try writeMirror()
            sidebar.finishSidebarSyncRecovery()
            fetched.removeAll()
            deleted.removeAll()
            deletedNames.removeAll()
            first = false
            fetching = false
            applying = false
            lastError = nil
            lastSync = date
            flushHeldChanges(on: engine)
        } catch {
            applying = false
            fetching = true
            lastError = localized("The incoming sidebar could not be applied and saved.")
        }
    }

    /// Merges first-sync identities and applies the resulting sidebar and settings.
    private func applyFirst(local: [SyncRecord], server: [SyncRecord], date: Date) throws {
        let held = IncomingSidebarRecords.heldOut(server: server, local: local, deleted: deleted)
        let plan = try FirstSyncMerge.plan(local: local.filter { !held.contains($0.recordName) }, server: server.filter { !held.contains($0.recordName) },
                                           samePage: { $0.isSamePage(as: $1) })
        var replacements = SidebarSyncReplacements()
        for match in plan.replacements {
            guard let old = UUID(uuidString: match.localName), let new = UUID(uuidString: match.serverName) else { continue }
            switch match.type {
            case .space: replacements.spaces[old] = new
            case .folder: replacements.folders[old] = new
            case .tab: replacements.tabs[old] = new
            case .favorite: replacements.favorites[old] = new
            case .siteRule: replacements.siteRules[old] = new
            case .persona, .setting: break
            }
        }
        var rows = plan.recordsToApply
        for upload in plan.recordsToUpload { rows[upload.recordName] = upload }
        let incoming = try IncomingSidebarRecords.plan(records: Array(rows.values), deleted: deleted, foundAt: date, defaultEngine: sidebar.defaultEngine)
        sidebar.applyFirstSidebarSync(incoming.sidebar, replacements: replacements)
        for item in plan.recordsToApply.values where item.recordType == .setting { settings.apply(item) }
        if !deleted.isEmpty || !incoming.recordsToDelete.isEmpty { sidebar.applySidebarSync(incoming.sidebar, deletions: incoming.deletions) }
    }

    /// Three-way merges fetched sidebar records and settings with local edits.
    private func applyFetched(local: [SyncRecord], server: [SyncRecord], base: [SyncRecord], date: Date) throws {
        // Only a changed local field takes an edit time from this Mac. Preserve the server's
        // times and order keys for unedited values before a three-way merge.
        let held = IncomingSidebarRecords.heldOut(server: base, local: local)
        let canSyncSiteRules = sidebar.sidebarSyncState.canSyncSiteRules
        let scope = { (record: SyncRecord) in record.recordType != .setting && !held.contains(record.recordName) && (canSyncSiteRules || record.recordType != .siteRule) }
        let differences = SyncDiff.changes(local: local.filter(scope), scope: scope, mirror: base, pending: mirror.pendingSaves, foundAt: date)
        // A name listed twice counts by its first copy, as in the comparison itself.
        let changed = Dictionary(differences.saves.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })
        let baseByName = Dictionary(base.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })
        let current = local.map { held.contains($0.recordName) ? $0 : changed[$0.recordName] ?? baseByName[$0.recordName] ?? $0 }
        // A record already deleted on this Mac must stay absent while its pending delete
        // is being sent. An edit of that same surviving server ID cannot restore it.
        let localDeletions = Set(differences.deletions).subtracting(reapplying)
        let incoming = try IncomingSidebarRecords.plan(local: current, fetched: server.filter { !localDeletions.contains($0.recordName) },
                                                     mirror: base, deleted: deleted, foundAt: date, defaultEngine: sidebar.defaultEngine)
        sidebar.applySidebarSync(incoming.sidebar, deletions: incoming.deletions)
        for item in server where item.recordType == .setting {
            let pending = mirror.pendingSaves.first { $0.recordName == item.recordName }
            let value = pending.map { SyncMerge.merge(local: $0, server: item, base: baseByName[item.recordName].map(SyncMerge.Base.mirror) ?? .firstWrite).record } ?? item
            settings.apply(value)
        }
        // Persist these times in the next comparisons; the mirror still takes the server's copy.
        let merged = Set(incoming.repairs.map(\.recordName))
        mirror.pendingSaves.removeAll { merged.contains($0.recordName) }
        mirror.pendingSaves.append(contentsOf: incoming.repairs)
    }

    /// Updates the mirror for sent changes and schedules conflict or missing-zone recovery.
    private func didSend(_ sent: SyncSentChanges) {
        guard let engine else { return }
        for row in sent.savedRecords where SyncCloudKitRecords.isInZone(row.recordID) { mirror.records[row.recordID.recordName] = row }
        for key in sent.deletedRecordNames { mirror.records[key] = nil }
        var conflicts: [CKRecord] = []
        for refused in sent.failedSaves {
            switch refused.failure {
            case .serverRecordChanged(let server):
                if SyncCloudKitRecords.isInZone(server.recordID), server.recordID.recordName == refused.recordName { conflicts.append(server) }
            case .unknownItem: unknown.insert(refused.recordName)
            case .zoneNotFound:
                if mirror.records.isEmpty {
                    awaitingZoneSave = true
                    engine.add([.saveZone, .saveRecord(refused.recordName)])
                } else { missingZone = true }
            case .other(let code):
                refusedSaves[refused.recordName] = mirror.pendingSaves.first { $0.recordName == refused.recordName }
                lastError = localized("A sync save failed (\(code.rawValue)).")
            }
        }
        if !unknown.isEmpty || missingZone {
            fetching = true
            needsRecoveryFetch = true
            Task { @MainActor [weak self] in
                guard let self, self.engine === engine, needsRecoveryFetch else { return }
                await requestFetch()
            }
        }
        if !conflicts.isEmpty {
            buffer(SyncFetchedChanges(records: conflicts))
            if !fetching { finishFetch() }
        } else if canSendRecords {
            do {
                if let durableSidebar { try compareSidebar(durableSidebar) }
                compareSettings()
                persist()
            }
            catch { lastError = localized("The pending sidebar changes could not be compared.") }
        }
    }

    /// `CKSyncEngine` asks for a batch when changes are added, and gets none while records are held; the comparisons add no change it already holds. So once a hold ends, the held changes go now.
    private func flushHeldChanges(on engine: any SyncEngineClient) {
        guard engine.pendingChanges.contains(where: { if case .saveRecord = $0 { true } else if case .deleteRecord = $0 { true } else { false } }) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.engine === engine, canSendRecords, !awaitingZoneSave else { return }
            try? await guarded { try await engine.sendChanges() }
        }
    }

    private func persist() {
        guard canSendRecords else { return }
        do { try writeMirror() }
        catch { lastError = localized("The sync state could not be saved.") }
    }

    /// Writes the mirror with the latest pending engine state.
    private func writeMirror() throws {
        guard let database else { return }
        var checkpoint = mirror
        if let pendingState { checkpoint.engineState = pendingState }
        try checkpoint.write(to: url, database: database)
        mirror = checkpoint
        pendingState = nil
    }

    /// Each engine's weak delegate expires when the controller leaves its database, even while
    /// CloudKit is completing a stop or delivering a previously queued callback.
    @MainActor private final class Delegate: SyncEngineDelegate {
        weak var owner: SyncController?
        init(_ owner: SyncController) { self.owner = owner }
        var canSendRecords: Bool {
            owner?.delegate === self && owner?.canSendRecords == true && owner?.awaitingZoneSave == false
        }
        func record(toSave name: String) -> CKRecord? {
            guard canSendRecords else { return nil }
            return owner?.record(toSave: name)
        }
        // Not gated on `canSendRecords`: each call before a batch has its call after, even once the engine stops.
        func willBuildBatch() { owner?.holdGuard() }
        func didBuildBatch() { owner?.releaseGuard() }
        func handle(_ event: SyncEvent) {
            guard owner?.delegate === self else { return }
            owner?.handle(event)
        }
    }
}
