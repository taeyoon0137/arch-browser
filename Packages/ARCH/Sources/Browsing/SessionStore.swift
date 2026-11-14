// Saves and restores sidebar state (Personas, spaces, favorites and their tabs, tabs, tab folders, closed tabs, and split views) and the main windows in the JSON file `session.json`. The session supplies the app's Application Support folder.
import ARCHEngine
import Darwin
import Foundation
import os

struct SessionSnapshot: Codable {
    /// Version 2 adds each tab's engine, version 3 its restorable page state, version 4 each space's home page, version 5 the favorites' tabs, version 6 tab folders, version 7 each space's split view, version 8 each tab's ID, version 9 the Personas with the Persona of each space, favorite, and tab, version 10 the deleted Personas whose stored data the engines still have to remove, version 11 the main windows, version 12 each open tab's suggested title, version 13 seals the page state (`SessionStateSeal`), version 14 adds each pinned tab's saved page, version 15 each folder's parent folder, and version 16 each live folder's configuration and each item tab's item. Files without a version are version 1.
    static let currentVersion = 16

    struct TabRecord: Codable, Equatable {
        /// The tab's ID. `nil` in files before version 8; `normalized()` gives every record one.
        var id: UUID?
        var spaceID: UUID
        var url: URL?
        var title: String
        /// The user's tab name. `nil` when the tab shows its page's title or the file predates tab renaming.
        var customTitle: String?
        var isPinned: Bool
        /// The folder that held the tab. `nil` outside folders and in files before version 6.
        var folderID: UUID?
        /// `nil` in closed-tab records and in files written before activation tracking.
        var lastActivatedAt: Date?
        /// `nil` in version 1 files; such a tab opens in the default engine.
        var engine: EngineKind?
        /// The engine's restorable page state, such as WebKit's back-forward list, which the file keeps sealed from version 13. `nil` for engines that keep none, in closed-tab records, in files before version 3, and when the state cannot be sealed or opened.
        var state: Data?
        /// The tab's Persona. `nil` in files before version 9; `normalized()` gives an open tab its space's Persona, and a closed tab keeps its own.
        var personaID: UUID?
        /// The name a hook gave the tab's document, or the user's refusal of it, with the document's address. `nil` without either, in closed-tab records, and in files before version 12.
        var suggestedTitle: SuggestedTitle?
        /// A pinned tab's saved page (bookmark rule 2), which open and closed records keep, so that a reopened pinned tab returns with it. `nil` for unpinned tabs and in files before version 14; `normalized()` gives a pinned record, open or closed, its address and title.
        var savedPage: SavedPage?
        /// The ID of the live folder item whose tab this is (live folder rule 4), in the live folder `folderID`. `nil` for every other tab, in closed records, since an item's tab never joins the closed list, and in files before version 16; `normalized()` drops one outside a live folder.
        var liveItemID: String?

        /// The record as the closed list keeps it: without the activation date, page state, hook's name, and live folder item, which a reopened tab does not use.
        var closed: TabRecord {
            var record = self
            record.lastActivatedAt = nil
            record.state = nil
            record.suggestedTitle = nil
            record.liveItemID = nil
            return record
        }

        /// The record under bookmark rule 2: an unpinned record keeps no saved page, and a pinned record without one, open or closed as in files before version 14, takes its address and title. A closed record needs it as much as an open one: a WebKit page reports the address it opens at before its tab exists, so a pinned tab reopened without a saved page would take the next address it reports.
        func repairingSavedPage() -> TabRecord {
            var record = self
            if !isPinned {
                record.savedPage = nil
            } else if savedPage == nil, let url {
                record.savedPage = SavedPage(url: url, title: title)
            }
            return record
        }
    }

    /// The most records the closed list keeps. The oldest go first.
    static let maximumClosedTabs = 100

    /// A favorite's tab, which opens where it was when the favorite is next opened.
    struct FavoriteTabRecord: Codable {
        /// The tab's ID, as in a tab record.
        var id: UUID?
        var favoriteID: UUID
        var url: URL?
        var engine: EngineKind
        /// The engine's restorable page state, as in a tab record.
        var state: Data?
    }

    /// A main window: what it shows and where it was.
    struct WindowRecord: Codable {
        var id: UUID
        /// The frame outside full screen, in screen coordinates. `nil` for a window that has never opened, which opens centered.
        var frame: CGRect?
        var currentSpaceID: UUID
        var selectedTabID: UUID?
        var isSidebarVisible: Bool
    }

    var version: Int?

    /// Every Persona, the default one among them. `nil` in files before version 9.
    var personas: [Persona]?
    /// Deleted Personas whose cookies and website data the engines remove at the next launch, before any engine starts. `nil` in files before version 10.
    var removedPersonaIDs: [UUID]?
    var spaces: [Space]
    /// The front main window's space, written for builds before version 11. `normalized()` reads it to make the window of a file without `windows`.
    var currentSpaceID: UUID
    var favorites: [Favorite]
    var tabs: [TabRecord]
    /// Every space's folders, in sidebar order among the folders of each parent and list, each with its parent from version 15 and a live folder's configuration from version 16. Optional so files before version 6 still decode.
    var folders: [TabFolder]?
    /// The index in `tabs` of the front main window's selected tab, written for builds before version 11. `normalized()` reads it, when `selectedFavoriteID` names no favorite tab, to select the tab of the window it makes for a file without `windows`.
    var selectedTabIndex: Int?
    /// Recently closed tabs, oldest first, at most `maximumClosedTabs` of them, each as `TabRecord.closed` keeps it. Optional so older files without this field still decode.
    var closedTabs: [TabRecord]?
    /// Each space's split view as indexes into `tabs`, left to right; the tabs' space is the split view's. `nil` in files before version 7.
    var splitViews: [[Int]]?
    /// The favorites' tabs, in favorite order. `nil` in files before version 5.
    var favoriteTabs: [FavoriteTabRecord]?
    /// The favorite whose tab the front main window selected, written for builds before version 11. `normalized()` reads it first to select the tab of the window it makes for a file without `windows`. `nil` when a space's tab was selected and in files before version 5.
    var selectedFavoriteID: UUID?
    /// The main windows, front to back. `nil` in files before version 11; `normalized()` makes one from `currentSpaceID` and the selected tab.
    var windows: [WindowRecord]?

    /// Fills in what older files lack and repairs what a file got wrong. The only migration point: `SessionStore.load()` returns every snapshot through it.
    func normalized() -> SessionSnapshot {
        // Every tab record, whether open, a favorite's, or closed, has an ID of its own. Records from files before version 8 have none, and a record that repeats an earlier record's ID gets a new one, so open tabs keep theirs first.
        var usedIDs: Set<UUID> = []
        func withUniqueIDs<Record>(_ records: [Record], at id: WritableKeyPath<Record, UUID?>) -> [Record] {
            records.map { record in
                if let kept = record[keyPath: id], usedIDs.insert(kept).inserted { return record }
                var record = record
                record[keyPath: id] = UUID()
                return record
            }
        }
        var snapshot = self
        snapshot.tabs = withUniqueIDs(tabs, at: \.id)
        snapshot.favoriteTabs = favoriteTabs.map { withUniqueIDs($0, at: \.id) }
        snapshot.closedTabs = closedTabs.map { withUniqueIDs($0, at: \.id) }
        // Earlier builds kept an archived tab's page state and activation date in its closed record, and more records than the list keeps.
        snapshot.closedTabs = snapshot.closedTabs.map { $0.suffix(Self.maximumClosedTabs).map(\.closed) }
        snapshot.folders = folders.map { LiveFolderTabs.repairingLiveFolders(FolderTree.repairingParents(of: LiveFolderTabs.pinningLiveFolders($0))) }
        snapshot.tabs = LiveFolderTabs.repairingItems(of: snapshot.tabs, in: snapshot.folders ?? [])
        snapshot.tabs = snapshot.tabs.map { $0.repairingSavedPage() }
        snapshot.closedTabs = snapshot.closedTabs.map { $0.map { $0.repairingSavedPage() } }
        snapshot.assignPersonas()
        snapshot.repairWindows()
        // Only a Persona that is gone loses its stored data. The default Persona is always listed, so the engines' default storage is never removed.
        let listedIDs = Set((snapshot.personas ?? []).map(\.id))
        snapshot.removedPersonaIDs = removedPersonaIDs?.filter { !listedIDs.contains($0) }
        return snapshot
    }

    /// What the session starts from when nothing was saved or the file did not load. Normalizing it gives the default Persona and its first space.
    static var empty: SessionSnapshot { SessionSnapshot(spaces: [], currentSpaceID: UUID(), favorites: [], tabs: []) }

    /// Gives every space and favorite a listed Persona, every Persona a space, and the tab records their Personas. Files before version 9 list none, so everything joins the default Persona. An item whose Persona is not listed joins the first Persona, as in sync's orphan rule.
    private mutating func assignPersonas() {
        // The default Persona is always there, first unless the file placed it elsewhere. A Persona listed twice keeps its first place.
        var listed: Set<UUID> = []
        var personas = (self.personas ?? []).filter { listed.insert($0.id).inserted }
        if !listed.contains(Persona.defaultID) {
            personas.insert(Persona(id: Persona.defaultID, name: "Default"), at: 0)
            listed.insert(Persona.defaultID)
        }
        let firstPersonaID = personas[0].id
        func knownPersonaID(_ id: UUID?) -> UUID {
            guard let id else { return Persona.defaultID }
            return listed.contains(id) ? id : firstPersonaID
        }
        for index in spaces.indices { spaces[index].personaID = knownPersonaID(spaces[index].personaID) }
        for index in favorites.indices { favorites[index].personaID = knownPersonaID(favorites[index].personaID) }
        // Each Persona's spaces sit together in Persona order and keep their own order. A Persona without spaces gets one, as at first launch.
        spaces = personas.flatMap { persona in
            let own = spaces.filter { $0.personaID == persona.id }
            return own.isEmpty ? [Space(name: "Personal", personaID: persona.id)] : own
        }
        // An open tab belongs to its space's Persona; a record whose space is gone does not reopen, so it stays as it is. A closed tab keeps its own Persona, or takes its space's, or the default Persona.
        let spacePersonaIDs = Dictionary(spaces.map { ($0.id, $0.resolvedPersonaID) }, uniquingKeysWith: { first, _ in first })
        for index in tabs.indices { tabs[index].personaID = spacePersonaIDs[tabs[index].spaceID] ?? tabs[index].personaID }
        closedTabs = closedTabs?.map { record in
            var record = record
            record.personaID = record.personaID ?? spacePersonaIDs[record.spaceID] ?? Persona.defaultID
            return record
        }
        self.personas = personas
    }

    /// Gives the snapshot at least one main window and each window a listed space and a tab that reopens, so that the windows open as they were. A file before version 11 lists none, so one window opens on its space and selected tab, with the sidebar visible and no frame.
    private mutating func repairWindows() {
        if windows?.isEmpty != false {
            let selectedFavoriteTabID = favoriteTabs?.first { $0.favoriteID == selectedFavoriteID }?.id
            let selectedTabID = selectedFavoriteTabID ?? selectedTabIndex.flatMap { tabs.indices.contains($0) ? tabs[$0].id : nil }
            windows = [WindowRecord(id: UUID(), frame: nil, currentSpaceID: currentSpaceID, selectedTabID: selectedTabID, isSidebarVisible: true)]
        }
        // The tabs that reopen: those of listed spaces, and the tabs of listed favorites, which show in any space.
        let spaceIDs = Set(spaces.map(\.id))
        let firstSpaceID = spaces[0].id
        let tabSpaceIDs = Dictionary(tabs.filter { spaceIDs.contains($0.spaceID) }.compactMap { record in record.id.map { ($0, record.spaceID) } }, uniquingKeysWith: { first, _ in first })
        let favoriteIDs = Set(favorites.map(\.id))
        let favoriteTabIDs = Set((favoriteTabs ?? []).filter { favoriteIDs.contains($0.favoriteID) }.compactMap(\.id))
        // A window whose tab does not reopen, or whose tab a window in front of it selects, picks its tab at launch. A window shows its tab's space.
        var claimedTabIDs: Set<UUID> = []
        windows = windows?.map { record in
            var record = record
            if !spaceIDs.contains(record.currentSpaceID) { record.currentSpaceID = firstSpaceID }
            guard let tabID = record.selectedTabID else { return record }
            let tabSpaceID = tabSpaceIDs[tabID]
            if (tabSpaceID == nil && !favoriteTabIDs.contains(tabID)) || !claimedTabIDs.insert(tabID).inserted {
                record.selectedTabID = nil
            } else if let tabSpaceID {
                record.currentSpaceID = tabSpaceID
            }
            return record
        }
    }
}

extension SessionSnapshot {
    /// The snapshot with the page state of each open tab and favorite's tab passed through `transform`, which leaves out a state it returns nil for.
    func mappingPageState(_ transform: (Data) -> Data?) -> SessionSnapshot {
        var snapshot = self
        snapshot.tabs = tabs.map { record in
            var record = record
            record.state = record.state.flatMap(transform)
            return record
        }
        snapshot.favoriteTabs = favoriteTabs?.map { record in
            var record = record
            record.state = record.state.flatMap(transform)
            return record
        }
        return snapshot
    }

    /// The space tabs and folders that `session.json` keeps: agent folders and their tabs stay out (docs/agents.md, agent decision 10), so that an agent's tabs never reopen at the next launch. A folder whose tabs the user kept is an ordinary folder.
    static func keptSidebar(tabs: [Tab], folders: [TabFolder]) -> (tabs: [Tab], folders: [TabFolder]) {
        var agentFolderIDs = Set(folders.filter(\.isAgentFolder).map(\.id))
        guard !agentFolderIDs.isEmpty else { return (tabs, folders) }
        // An older hierarchy can contain descendants of an agent folder. Its owner marker is
        // intentionally never encoded, so exclude the whole subtree before writing the file.
        let children = Dictionary(grouping: folders, by: \.parentID)
        var pending = Array(agentFolderIDs)
        while let parent = pending.popLast() {
            for folder in children[parent] ?? [] where agentFolderIDs.insert(folder.id).inserted {
                pending.append(folder.id)
            }
        }
        return (tabs.filter { $0.folderID.map { !agentFolderIDs.contains($0) } ?? true }, folders.filter { !agentFolderIDs.contains($0.id) })
    }
}

extension SessionSnapshot.TabRecord {
    /// An open tab as `session.json` keeps it, in the space `spaceID` and active last at `lastActivatedAt`. A tab without its page writes what its stand-in keeps of its saved record (`UnloadedWebContents`).
    init(_ tab: Tab, spaceID: UUID, lastActivatedAt: Date) {
        self.init(id: tab.id, spaceID: spaceID, url: tab.url, title: tab.title, customTitle: tab.customTitle, isPinned: tab.isPinned, folderID: tab.folderID, lastActivatedAt: lastActivatedAt,
                  engine: tab.engineKind, state: tab.webContents.restorableState, personaID: tab.personaID, suggestedTitle: tab.suggestedTitle, savedPage: tab.savedPage,
                  liveItemID: tab.liveItemID)
    }
}

final class SessionStore {
    let fileURL: URL
    private var pendingSave: DispatchWorkItem?
    /// Set on the main thread. Replacing the observer discards deliveries for the previous one.
    var didWrite: ((SessionSnapshot) -> Void)? {
        didSet { observerRevision &+= 1 }
    }
    private var observerRevision: UInt64 = 0

    private static let log = Logger(subsystem: "xyz.taeyoon.arch", category: "Session")
    /// Encodes and writes the snapshots in the order they were taken, away from the main thread.
    private let writeQueue = DispatchQueue(label: "xyz.taeyoon.arch.session-store", qos: .utility)
    /// If setting a file aside at launch failed, retry before the next write replaces its contents.
    private var pendingBackup: URL?
    /// Seals the page state in the file. The tests give one with a key of their own, so they never touch the Keychain.
    private let seal: SessionStateSeal

    init(directory: URL, seal: SessionStateSeal = .keychain) {
        fileURL = directory.appendingPathComponent("session.json")
        self.seal = seal
    }

    /// Where `load()` sets aside a file that does not decode. While a file is there, the live folders' service keeps the entries and Keychain items of the folders it may hold (`LiveFolderService(keepsUnknownFolders:)`).
    private var unreadableFileURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("session.unreadable.json") }

    /// Read at startup so a session still awaiting backup also keeps its live folders' local data.
    var keepsUnknownLiveFolders: Bool { pendingBackup != nil || FileManager.default.fileExists(atPath: unreadableFileURL.path) }

    /// The saved session, or nil when there is none or it cannot be read. A file from a newer build first leaves a copy, `session-v<version>.json`, which keeps that build's fields once this build saves without them. A file that does not decode moves to `session.unreadable.json`, so the fresh session never overwrites it. Either copy replaces an older one.
    func load() -> SessionSnapshot? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            pendingBackup = unreadableFileURL
            return nil
        }
        let directory = fileURL.deletingLastPathComponent()
        if let version = try? JSONDecoder().decode(SavedVersion.self, from: data).version, version > SessionSnapshot.currentVersion {
            let backup = directory.appendingPathComponent("session-v\(version).json")
            do {
                try Self.write(data, to: backup)
            } catch {
                pendingBackup = backup
            }
        }
        guard let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else {
            // Keep a newer version's original in place while its versioned backup is pending.
            if pendingBackup == nil {
                do {
                    try Self.rename(fileURL, to: unreadableFileURL)
                } catch {
                    pendingBackup = unreadableFileURL
                }
            }
            return nil
        }
        return snapshot.mappingPageState(seal.open).normalized()
    }

    /// The version a file was written with, read on its own so that a newer file is copied even when the rest does not decode.
    private struct SavedVersion: Decodable {
        var version: Int?
    }

    /// Combines rapid changes, such as tab updates, into one file write. Runs the `snapshot` closure on the main thread half a second after the last call, not when scheduling, and writes nothing when it returns nil, as once the session is gone. The file is written on `writeQueue`.
    func scheduleSave(_ snapshot: @escaping () -> SessionSnapshot?) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let snapshot = snapshot() else { return }
            let notify = self.completion(for: snapshot)
            self.writeQueue.async {
                if case .success = self.write(snapshot) { notify?() }
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Saves in place of a scheduled write and waits for all earlier writes. Quitting checks the result.
    @discardableResult
    func saveNow(_ snapshot: SessionSnapshot) -> Result<Void, Error> {
        pendingSave?.cancel()
        let notify = completion(for: snapshot)
        return writeQueue.sync {
            let result = write(snapshot)
            if case .success = result { notify?() }
            return result
        }
    }

    /// The serial writer queues successful captures back onto main in their actual file order,
    /// including synchronous flushes that overtake a previously queued main-thread callback.
    private func completion(for snapshot: SessionSnapshot) -> (() -> Void)? {
        guard didWrite != nil else { return nil }
        let revision = observerRevision
        return { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.observerRevision == revision else { return }
                self.didWrite?(snapshot)
            }
        }
    }

    @discardableResult
    private func write(_ snapshot: SessionSnapshot) -> Result<Void, Error> {
        do {
            let data = try JSONEncoder().encode(snapshot.mappingPageState(seal.seal))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let backup = pendingBackup {
                try Self.write(Data(contentsOf: fileURL), to: backup)
                pendingBackup = nil
            }
            try Self.write(data, to: fileURL)
            return .success(())
        } catch {
            let error = error as NSError
            Self.log.error("Saving session.json failed (\(error.domain, privacy: .public) \(error.code)).")
            return .failure(error)
        }
    }

    /// Set permissions before the first byte is written. Only a complete file replaces the previous one.
    private static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".session-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.close()
        try rename(temporary, to: destination)
    }

    private static func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
