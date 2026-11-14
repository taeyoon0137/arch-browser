// Coordinates the signed-in user's private sync database. The account check must succeed
// and the user's toggle must be on before the controller starts a sync engine.
import Browsing
import CloudKit
import Foundation

@MainActor public final class SyncController {
    public static let enabledKey = "ARCHSyncEnabled"
    public private(set) var availability: SyncAvailability.Status = .unavailable(.temporarilyUnavailable)
    public private(set) var isEnabled: Bool
    public private(set) var isDeletingCloudData = false
    public private(set) var offReason: SyncOffReason?
    public var statusExplanation: String? {
        switch availability {
        case .unavailable(let reason): reason.message
        case .available: offReason?.message
        }
    }
    public private(set) var lastError: String?
    public private(set) var lastSync: Date?
    public let settings: SyncedSettings

    private let sidebar: any SyncedSidebar
    private let defaults: UserDefaults
    private let url: URL
    private let check: () async -> SyncAvailability.Status
    private let factory: SyncEngineFactory
    private let now: () -> Date
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var checkNumber = 0
    private var database: SyncDatabase?
    private var engine: (any SyncEngineClient)?
    private var delegate: Delegate?
    private var mirror = SyncMirror()
    private var durableSidebar: SidebarSyncState?
    private var refusedSaves: [String: SyncRecord] = [:]
    private static let offReasonKey = "ARCHSyncOffReason"
    private static let discardStateKey = "ARCHSyncDiscardPreviousState"
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

    public convenience init(sidebar: any SyncedSidebar, directory: URL, defaults: UserDefaults = .standard) {
        let availability = SyncAvailability()
        self.init(sidebar: sidebar, directory: directory, defaults: defaults, check: availability.check,
                  factory: { CloudKitSyncEngine(database: $0, stateSerialization: $1, delegate: $2) })
        if let entitlement = availability.entitledDatabase() {
            let container = CKContainer(identifier: entitlement.containerIdentifier)
            observeAccountChanges(of: container)
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
        observeSidebarSaves()
        observers.append(notifications.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
    }

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

    public func setEnabled(_ enabled: Bool) async {
        guard !isDeletingCloudData else { return }
        if enabled { recordOffReason(nil) }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled { await refresh() } else { checkNumber += 1; await stop() }
    }

    /// Called after the user confirms the deletion. Keep the previous file until the server
    /// confirms the zone is gone. Interrupted or refused requests can be retried explicitly.
    public func deleteCloudData() async {
        guard let engine, isEnabled, !isDeletingCloudData else { return }
        isDeletingCloudData = true
        lastError = nil
        engine.add([.deleteZone])
        await sendZoneDeletion(on: engine)
    }

    private func sendZoneDeletion(on engine: any SyncEngineClient) async {
        guard !deletionSendInFlight else { return }
        lastError = nil
        deletionSendInFlight = true
        defer { if self.engine === engine { deletionSendInFlight = false } }
        do { try await engine.sendChanges() }
        catch {
            if self.engine === engine, !engine.pendingChanges.contains(.deleteZone) {
                lastError = "Arch could not delete its iCloud data."
            }
        }
        guard self.engine === engine, isDeletingCloudData else { return }
        if engine.pendingChanges.contains(.deleteZone), lastError == nil {
            // CloudKit owns retries for offline and temporarily unavailable accounts. Keep the
            // live request scoped to this engine. A relaunch starts from the pre-deletion file.
            lastError = "Arch is waiting to delete its iCloud data."
            return
        }
        await resumeAfterDeleteFailure(on: engine,
            message: lastError ?? "Arch could not delete its iCloud data. Try again when connected.")
    }

    private func resumeAfterDeleteFailure(on engine: any SyncEngineClient, message: String) async {
        engine.remove([.deleteZone])
        isDeletingCloudData = false
        await requestFetch()
        if self.engine === engine { lastError = message }
    }

    /// Called on launch and activation, and by the entitled container's account notification.
    public func refresh() async {
        checkNumber += 1
        let number = checkNumber
        let result = await check()
        guard number == checkNumber else { return }
        availability = result
        if case .unavailable(.noAccount) = result, isEnabled {
            // The availability notification can arrive before the engine's sign-out event.
            // Invalidate its token now so a subsequent account cannot resume it.
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
                lastError = "The previous sync state could not be removed."
                return
            }
            mirror = SyncMirror.read(from: url, database: target)
            first = mirror.isEmpty
            fetching = true
            lastError = nil
            let delegate = Delegate(self)
            self.delegate = delegate
            engine = factory(target, mirror.engineState, delegate)
        }
        if isDeletingCloudData {
            if let engine { await sendZoneDeletion(on: engine) }
            return
        }
        refusedSaves.removeAll()
        if awaitingZoneSave { engine?.add([.saveZone]) }
        await requestFetch()
    }

    private func stop() async {
        await detach()?.stop()
    }

    private func detach() -> (any SyncEngineClient)? {
        let previous = engine
        engine = nil
        delegate = nil
        isDeletingCloudData = false
        deletionSendInFlight = false
        database = nil
        needsRecoveryFetch = false
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

    private func requestFetch() async {
        if let fetchTask { await fetchTask.value; return }
        guard let engine else { return }
        fetching = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                needsRecoveryFetch = false
                do { try await engine.fetchChanges() }
                catch {
                    if self.engine === engine, fetching { lastError = "The sync fetch did not finish." }
                }
            } while self.engine === engine && needsRecoveryFetch
            if self.engine === engine { fetchTask = nil }
        }
        fetchTask = task
        await task.value
    }

    public var canSendRecords: Bool { engine != nil && !first && !fetching && !applying && !isDeletingCloudData }
    public func record(toSave name: String) -> CKRecord? {
        guard canSendRecords, let save = mirror.pendingSaves.first(where: { $0.recordName == name }) else { return nil }
        let base = mirror.records[name]
        guard base.map({ $0.recordType == save.recordType.rawValue }) ?? true else { return nil }
        return SyncCloudKitRecords.ckRecord(from: save, base: base)
    }

    private var bases: [SyncRecord] { mirror.records.values.compactMap(SyncCloudKitRecords.syncRecord(from:)) }
    private func sidebarSaved(_ state: SidebarSyncState) {
        guard engine != nil, !applying else { return }
        durableSidebar = state
        do {
            try compareSidebar(state)
            if canSendRecords { persist() }
        } catch { lastError = "The saved sidebar could not be compared." }
    }

    func settingsChanged() {
        let keys = settings.changedKeys()
        guard engine != nil, !keys.isEmpty, !applying else { return }
        compareSettings()
        if canSendRecords { persist() }
    }

    private func compareSidebar(_ state: SidebarSyncState, publish: Bool? = nil) throws {
        let date = now()
        let records = try SidebarRecords.records(from: state, foundAt: date)
        let changes = SyncDiff.changes(local: records, scope: { $0.recordType != .setting }, mirror: bases, pending: mirror.pendingSaves, foundAt: date)
        reconcile(changes, publish: publish ?? canSendRecords, includes: { $0.recordType != .setting })
    }

    private func compareSettings(publish: Bool? = nil) {
        let comparison = settings.comparison(mirror: bases, pending: mirror.pendingSaves)
        let changes = SyncDiff.changes(local: comparison.records, scope: comparison.contains, mirror: bases, pending: mirror.pendingSaves, foundAt: now())
        reconcile(changes, publish: publish ?? canSendRecords, includes: { $0.recordType == .setting })
    }

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
                lastError = "The sync fetch did not finish (\(error.rawValue))."
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
                    let message = "Arch could not delete its iCloud data (\(refusal.rawValue))."
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
            if sent.savedZone { awaitingZoneSave = false }
            if sent.failedSave != nil { awaitingZoneSave = true }
            if let code = sent.failedSave ?? sent.failedDelete { lastError = "The sync zone change failed (\(code.rawValue))." }
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

    private func recordOffReason(_ reason: SyncOffReason?) {
        offReason = reason
        defaults.set(reason?.rawValue, forKey: Self.offReasonKey)
    }

    private func disableAfterLoss(_ reason: SyncOffReason) {
        recordOffReason(reason)
        lastError = nil
        lastSync = nil
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        checkNumber += 1
        let old = detach()
        defaults.set(true, forKey: Self.discardStateKey)
        do { try discardPreviousStateIfNeeded() }
        catch { lastError = "The previous sync state could not be removed." }
        Task { await old?.stop() }
    }

    private func discardPreviousStateIfNeeded() throws {
        guard defaults.bool(forKey: Self.discardStateKey) else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        defaults.removeObject(forKey: Self.discardStateKey)
    }

    private func finishFetch() {
        guard let engine else { return }
        applying = true
        do {
            let date = now()
            let base = bases
            // A defaults notification can still be waiting on the main queue.
            if !settings.changedKeys().isEmpty { compareSettings(publish: false) }
            let local = try SidebarRecords.records(from: sidebar.sidebarSyncState, foundAt: date)
            let server = fetched.values.compactMap(SyncCloudKitRecords.syncRecord(from:))
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
            fetched.removeAll()
            deleted.removeAll()
            deletedNames.removeAll()
            first = false
            fetching = false
            applying = false
            lastError = nil
            lastSync = date
        } catch {
            applying = false
            fetching = true
            lastError = "The incoming sidebar could not be applied and saved."
        }
    }

    private func applyFirst(local: [SyncRecord], server: [SyncRecord], date: Date) throws {
        let plan = try FirstSyncMerge.plan(local: local, server: server, samePage: { $0.isSamePage(as: $1) })
        var replacements = SidebarSyncReplacements()
        for match in plan.replacements {
            guard let old = UUID(uuidString: match.localName), let new = UUID(uuidString: match.serverName) else { continue }
            switch match.type {
            case .space: replacements.spaces[old] = new
            case .folder: replacements.folders[old] = new
            case .tab: replacements.tabs[old] = new
            case .favorite: replacements.favorites[old] = new
            case .persona, .setting: break
            }
        }
        var rows = plan.recordsToApply
        for upload in plan.recordsToUpload { rows[upload.recordName] = upload }
        let incoming = try IncomingSidebarRecords.plan(records: Array(rows.values), deleted: deleted, foundAt: date)
        sidebar.applyFirstSidebarSync(incoming.sidebar, replacements: replacements)
        for item in plan.recordsToApply.values where item.recordType == .setting { settings.apply(item) }
        if !deleted.isEmpty || !incoming.recordsToDelete.isEmpty { sidebar.applySidebarSync(incoming.sidebar, deletions: incoming.deletions) }
    }

    private func applyFetched(local: [SyncRecord], server: [SyncRecord], base: [SyncRecord], date: Date) throws {
        // Only a changed local field takes an edit time from this Mac. Preserve the server's
        // times and order keys for unedited values before a three-way merge.
        let differences = SyncDiff.changes(local: local, scope: { $0.recordType != .setting }, mirror: base, pending: mirror.pendingSaves, foundAt: date)
        let changed = Dictionary(uniqueKeysWithValues: differences.saves.map { ($0.recordName, $0) })
        let baseByName = Dictionary(uniqueKeysWithValues: base.map { ($0.recordName, $0) })
        let current = local.map { changed[$0.recordName] ?? baseByName[$0.recordName] ?? $0 }
        // A record already deleted on this Mac must stay absent while its pending delete
        // is being sent. An edit of that same surviving server ID cannot restore it.
        let localDeletions = Set(differences.deletions)
        let incoming = try IncomingSidebarRecords.plan(local: current, fetched: server.filter { !localDeletions.contains($0.recordName) },
                                                     mirror: base, deleted: deleted, foundAt: date)
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
                lastError = "A sync save failed (\(code.rawValue))."
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
            catch { lastError = "The pending sidebar changes could not be compared." }
        }
    }

    private func persist() {
        guard canSendRecords else { return }
        do { try writeMirror() }
        catch { lastError = "The sync state could not be saved." }
    }

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
        func handle(_ event: SyncEvent) {
            guard owner?.delegate === self else { return }
            owner?.handle(event)
        }
    }
}
