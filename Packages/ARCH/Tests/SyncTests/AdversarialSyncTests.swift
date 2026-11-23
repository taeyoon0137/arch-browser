import ARCHEngine
@testable import Browsing
import CloudKit
import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Sync

/// Records that another Mac, another build, or a damaged zone could hold, fed through the real fetch, merge, repair, apply, save, and relaunch on a second Mac (`docs/sync.md`, Mapping the session store to records ▸ Orphans and Schema versions). Each must leave the app running with a sidebar it can draw: no trap, each ID once, every item in a listed Persona and space, folders without cycles, sync still on, and the crash-loop guard released.
@MainActor @Suite struct AdversarialSyncTests {
    typealias Mac = TwoMacRecoveryTests.Mac
    typealias Zone = TwoMacRecoveryTests.Zone

    /// What the other Mac's records hold.
    enum Input: String, CaseIterable, Sendable {
        case folderCycle, selfParentFolder, deepFolders, parentInAnotherSpace
        case missingPersona, missingParents, crossPersona, personaWithoutSpaces, personalSpaceNameTaken
        case equalAndUnusableOrderKeys, unknownTypeAndNewerSchema, wrongValueKinds, malformedRecordNames
        case malformedEditTimesAndMetadata, malformedAddresses, otherZone, settings
        // Only an incremental fetch can bring these: deletions, a record that changed type, and the deletion of a Persona whose space and pin a window shows.
        case deletions, typeChange, personaDeletedWhileShown

        var needsEarlierSync: Bool { self == .deletions || self == .typeChange || self == .personaDeletedWhileShown }
    }

    /// The other Mac's sidebar, in the zone before the second Mac syncs.
    @MainActor struct Context {
        let space: String
        let folder: String
        let pin: String
        let favorite: String
        /// A Persona with one space and one pin, which the other Mac sent before `personaDeletedWhileShown` deletes them.
        let shownPersona = (persona: UUID().uuidString, space: UUID().uuidString, pin: UUID().uuidString)

        var shownPersonaRecords: [CKRecord] {
            [AdversarialSyncTests.persona(shownPersona.persona), AdversarialSyncTests.space(shownPersona.space, persona: shownPersona.persona),
             AdversarialSyncTests.tab(shownPersona.pin, space: shownPersona.space, persona: shownPersona.persona)]
        }
    }

    // MARK: Records

    static func record(_ type: SyncRecordType, _ name: String, _ fields: [String: SyncValue], order: Double? = 1, schemaVersion: Int = SyncRecord.currentSchemaVersion) -> CKRecord {
        var fields = fields
        if let order { fields["order"] = .number(order) }
        return SyncCloudKitRecords.ckRecord(from: SyncRecord(recordType: type, recordName: name, fields: fields, modifiedAt: Date(), schemaVersion: schemaVersion))
    }

    static func folder(_ name: String, space: String, parent: String? = nil, persona: String = "default", order: Double = 1) -> CKRecord {
        var fields: [String: SyncValue] = ["persona": .reference(persona), "space": .reference(space), "name": .text("Folder \(name.prefix(4))")]
        fields["parent"] = parent.map(SyncValue.reference)
        return record(.folder, name, fields, order: order)
    }

    static func tab(_ name: String, space: String, folder: String? = nil, persona: String = "default", order: Double = 1) -> CKRecord {
        var fields: [String: SyncValue] = ["persona": .reference(persona), "space": .reference(space), "url": .text("about:blank#\(name.prefix(4))"),
                                           "title": .text("Pin"), "engine": .text("webKit")]
        fields["folder"] = folder.map(SyncValue.reference)
        return record(.tab, name, fields, order: order)
    }

    static func space(_ name: String, persona: String = "default", order: Double = 2) -> CKRecord {
        record(.space, name, ["persona": .reference(persona), "name": .text("Space \(name.prefix(4))"), "symbol": .text("circle.fill"), "tint": .text("blue")], order: order)
    }

    static func favorite(_ name: String, persona: String = "default", url: String = "https://example.com/", order: Double = 2) -> CKRecord {
        record(.favorite, name, ["persona": .reference(persona), "url": .text(url), "title": .text("Favorite")], order: order)
    }

    static func persona(_ name: String, order: Double = 2) -> CKRecord {
        record(.persona, name, ["name": .text("Persona \(name.prefix(4))")], order: order)
    }

    static func id() -> String { UUID().uuidString }

    /// The name `IncomingSidebarRecords` gives the Personal space it adds to a Persona without spaces.
    static func personalSpaceName(for persona: UUID) -> String {
        var namespace = persona.uuid
        var bytes = withUnsafeBytes(of: &namespace) { Data($0) }
        bytes.append(contentsOf: "Arch Personal space".utf8)
        var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x50
        hash[8] = (hash[8] & 0x3f) | 0x80
        return hash.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }.uuidString
    }

    /// The records and deletions that `input` brings.
    static func changes(_ input: Input, in context: Context) -> SyncFetchedChanges {
        let space = context.space
        switch input {
        case .folderCycle:
            let first = id(), second = id(), third = id()
            return .init(records: [folder(first, space: space, parent: second), folder(second, space: space, parent: third),
                                   folder(third, space: space, parent: first), tab(id(), space: space, folder: second)])
        case .selfParentFolder:
            let looped = id()
            return .init(records: [folder(looped, space: space, parent: looped), tab(id(), space: space, folder: looped)])
        case .deepFolders:
            var records: [CKRecord] = []
            var parent: String?
            for level in 0..<9 {
                let name = id()
                records.append(folder(name, space: space, parent: parent, order: Double(level)))
                parent = name
            }
            records.append(tab(id(), space: space, folder: parent))
            return .init(records: records)
        case .parentInAnotherSpace:
            let other = id(), parent = id(), child = id()
            return .init(records: [self.space(other), folder(parent, space: space), folder(child, space: other, parent: parent),
                                   tab(id(), space: space, folder: child)])
        case .missingPersona:
            let gone = id(), lostSpace = id(), lostFolder = id()
            return .init(records: [self.space(lostSpace, persona: gone), folder(lostFolder, space: lostSpace, persona: gone),
                                   favorite(id(), persona: gone), tab(id(), space: lostSpace, folder: lostFolder, persona: gone)])
        case .missingParents:
            return .init(records: [tab(id(), space: space, folder: id()), tab(id(), space: id()), folder(id(), space: space, parent: id()),
                                   folder(id(), space: id()), folder(id(), space: id(), parent: id())])
        case .crossPersona:
            let other = id(), otherSpace = id(), otherFolder = id()
            return .init(records: [persona(other), self.space(otherSpace, persona: other), folder(otherFolder, space: otherSpace, persona: other),
                                   tab(id(), space: space, folder: otherFolder), folder(id(), space: space, parent: otherFolder),
                                   folder(id(), space: otherSpace), tab(id(), space: otherSpace, persona: other, order: 3),
                                   favorite(id(), persona: other)])
        case .personaWithoutSpaces:
            return .init(records: [persona(id()), persona(id(), order: 3), tab(id(), space: id(), persona: "default")])
        case .personalSpaceNameTaken:
            let empty = UUID()
            return .init(records: [persona(empty.uuidString), folder(personalSpaceName(for: empty), space: space)])
        case .equalAndUnusableOrderKeys:
            let orders: [Double] = [1, 1, 1, .nan, .infinity, -.infinity, 1e308, -1e308, .greatestFiniteMagnitude, .leastNonzeroMagnitude, -0.0]
            return .init(records: orders.map { tab(id(), space: space, order: $0) } + orders.map { favorite(id(), url: "https://example.com/\(UUID().uuidString)", order: $0) }
                + orders.prefix(4).map { self.space(id(), order: $0) } + orders.prefix(4).map { persona(id(), order: $0) }
                + orders.prefix(4).map { folder(id(), space: space, order: $0) })
        case .unknownTypeAndNewerSchema:
            let bookmark = CKRecord(recordType: "Bookmark", recordID: SyncCloudKitRecords.recordID(named: id()))
            bookmark["space"] = CKRecord.Reference(recordID: SyncCloudKitRecords.recordID(named: space), action: .none)
            bookmark.encryptedValues["name"] = "From a newer build"
            let newer = folder(id(), space: space)
            newer["schemaVersion"] = 99
            newer["since"] = Date()
            newer["colors"] = ["red", "blue"] as [String]
            newer["blob"] = Data([1, 2, 3])
            newer.encryptedValues["theme"] = "aurora"
            let newerTab = tab(id(), space: space)
            newerTab["schemaVersion"] = 99
            newerTab["location"] = CLLocation(latitude: 37.5, longitude: 127)
            return .init(records: [bookmark, newer, newerTab])
        case .wrongValueKinds:
            let spaceName = record(.space, id(), ["persona": .reference("default"), "name": .number(3), "symbol": .text("circle.fill"), "tint": .text("blue")])
            let folderPersona = record(.folder, id(), ["persona": .text("default"), "space": .reference(space), "name": .text("Kind")])
            let tabURL = record(.tab, id(), ["persona": .reference("default"), "space": .reference(space), "url": .reference(space), "title": .text("Pin")])
            let tabSpace = record(.tab, id(), ["persona": .reference("default"), "space": .number(1), "folder": .text("none"), "title": .text("Pin")])
            let favoriteTitle = record(.favorite, id(), ["persona": .reference("default"), "url": .text("https://example.com/kind"), "title": .number(1)])
            let tabOrder = record(.tab, id(), ["persona": .reference("default"), "space": .reference(space), "order": .text("first"), "customTitle": .number(2)], order: nil)
            let personaName = record(.persona, id(), ["name": .reference("default")])
            let folderParent = record(.folder, id(), ["persona": .reference("default"), "space": .reference(space), "parent": .number(4), "name": .text("Parent")])
            let spaceTint = record(.space, id(), ["persona": .reference("default"), "name": .text("Tint"), "symbol": .text(""), "tint": .text("ultraviolet")])
            return .init(records: [spaceName, folderPersona, tabURL, tabSpace, favoriteTitle, tabOrder, personaName, folderParent, spaceTint])
        case .malformedRecordNames:
            return .init(records: [self.space("not-a-uuid"), folder(UUID().uuidString.lowercased(), space: space), persona(Persona.defaultID.uuidString),
                                   tab("default", space: space), favorite("_system"), self.space(String(repeating: "x", count: 255)),
                                   tab(id(), space: "not-a-uuid"), folder(id(), space: space, parent: "default")])
        case .malformedEditTimesAndMetadata:
            let notJSON = tab(id(), space: space)
            notJSON.encryptedValues["fieldModifiedAt"] = "not json {"
            let huge = favorite(id(), url: "https://example.com/huge")
            huge.encryptedValues["fieldModifiedAt"] = "{\"title\": 1e308, \"url\": -1e308, \"order\": 0}"
            let wrongMetadata = folder(id(), space: space)
            wrongMetadata["modifiedAt"] = "yesterday"
            wrongMetadata["schemaVersion"] = "two"
            let bigVersion = self.space(id())
            bigVersion["schemaVersion"] = NSNumber(value: Int64.max)
            let negativeVersion = persona(id())
            negativeVersion["schemaVersion"] = -5
            let farDates = tab(id(), space: space)
            farDates["modifiedAt"] = Date.distantFuture
            farDates.encryptedValues["fieldModifiedAt"] = "{\"customTitle\": 9e300}"
            return .init(records: [notJSON, huge, wrongMetadata, bigVersion, negativeVersion, farDates])
        case .malformedAddresses:
            let addresses = ["not a url", "javascript:alert(1)", "", "http://[::1", "file:///etc/hosts", "https://", String(repeating: "a", count: 10_000), "http://%zz/", "💥://x"]
            var records = addresses.map { favorite(id(), url: $0) }
            for address in addresses {
                records.append(record(.tab, id(), ["persona": .reference("default"), "space": .reference(space), "url": .text(address), "title": .text("Odd")]))
                records.append(record(.space, id(), ["persona": .reference("default"), "name": .text("Home"), "symbol": .text("circle.fill"), "tint": .text("blue"), "homeURL": .text(address)], order: 5))
            }
            return .init(records: records)
        case .otherZone:
            let zone = CKRecordZone.ID(zoneName: "ArchSync2", ownerName: CKCurrentUserDefaultName)
            let outside = CKRecord(recordType: "Space", recordID: CKRecord.ID(recordName: space, zoneID: zone))
            outside.encryptedValues["name"] = "Other zone"
            let reference = tab(id(), space: space)
            reference["folder"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: context.folder, zoneID: zone), action: .none)
            return .init(records: [outside, reference])
        case .deletions:
            func deletion(_ name: String, _ type: String) -> SyncFetchedChanges.Deletion {
                .init(recordID: SyncCloudKitRecords.recordID(named: name), recordType: type)
            }
            return .init(records: [], deletions: [deletion("default", "Persona"), deletion(space, "Space"), deletion(context.folder, "Folder"),
                                                  deletion(context.pin, "Bookmark"), deletion(context.favorite, "Tab"), deletion(id(), "Space"),
                                                  deletion(Persona.defaultID.uuidString, "Persona")])
        case .typeChange:
            return .init(records: [folder(space, space: space), tab(context.folder, space: space), persona(context.favorite),
                                   self.space(context.pin)])
        case .settings:
            func setting(_ key: String, _ value: SyncValue?) -> CKRecord {
                record(.setting, key, value.map { ["value": $0] } ?? [:], order: nil)
            }
            return .init(records: [setting("ARCHAppearance", .text("neon")), setting("ARCHTintStrength", .number(2)), setting("ARCHArchiveAfterHours", .text("99999999999999999999999")),
                                   setting("ARCHUnloadAfterHours", .text("-1")), setting("ARCHOpensLinksInSmallWindow", nil), setting("ARCHDefaultEngine", .text("chromium")),
                                   setting("ARCHFromANewerBuild", .text("on")), setting("ARCHAskWhereToSaveDownloads", .reference("default"))])
        case .personaDeletedWhileShown:
            let shown = context.shownPersona
            return .init(deletions: [.init(recordID: SyncCloudKitRecords.recordID(named: shown.persona), recordType: "Persona"),
                                     .init(recordID: SyncCloudKitRecords.recordID(named: shown.space), recordType: "Space"),
                                     .init(recordID: SyncCloudKitRecords.recordID(named: shown.pin), recordType: "Tab")])
        }
    }

    // MARK: Checks

    /// Whether the session is one the sidebar can draw: each ID once, every item in a listed Persona and space, a space for every Persona, and folders without cycles whose rows build.
    static func isSane(_ session: BrowserSession) -> Bool {
        let personas = Set(session.personas.map(\.id)), spaces = Set(session.spaces.map(\.id)), folders = Dictionary(session.folders.map { ($0.id, $0) }) { first, _ in first }
        guard personas.count == session.personas.count, spaces.count == session.spaces.count, folders.count == session.folders.count,
              Set(session.favorites.map(\.id)).count == session.favorites.count, Set(session.allTabs.map(\.id)).count == session.allTabs.count,
              personas.contains(Persona.defaultID), !session.spaces.isEmpty,
              session.spaces.allSatisfy({ personas.contains($0.resolvedPersonaID) }),
              personas.allSatisfy({ persona in session.spaces.contains { $0.resolvedPersonaID == persona } }),
              session.favorites.allSatisfy({ personas.contains($0.resolvedPersonaID) }),
              session.folders.allSatisfy({ spaces.contains($0.spaceID) }),
              session.tabs.allSatisfy({ tab in tab.spaceID.map(spaces.contains) ?? true }) else { return false }
        for folder in session.folders {
            var seen: Set<UUID> = [folder.id]
            var parent = folder.parentID
            while let next = parent {
                guard seen.insert(next).inserted else { return false }
                parent = folders[next]?.parentID
            }
        }
        let tree = session.folderTree
        for space in session.spaces {
            _ = tree.rows(in: space.id, pinned: true)
            _ = tree.rows(in: space.id, pinned: false)
            _ = session.tabs(in: space.id, pinned: true)
        }
        return true
    }

    private func fill(_ mac: Mac) throws -> Context {
        let space = try #require(mac.session.spaces.first)
        let folder = mac.session.makeFolder(in: space.id, pinned: true)
        let favorite = Favorite(url: URL(string: "about:blank#favorite")!, title: "Favorite", personaID: space.resolvedPersonaID)
        mac.session.addFavorites([favorite], in: space.resolvedPersonaID)
        let pin = SidebarSyncState.PinnedTab(id: UUID(), personaID: space.resolvedPersonaID, spaceID: space.id, folderID: folder.id,
                                             savedPage: .init(url: URL(string: "about:blank#pin")!, title: "Saved"), customTitle: nil, engine: .webKit)
        let state = mac.session.sidebarSyncState
        mac.session.applySidebarSync(.init(personas: state.personas, spaces: state.spaces, folders: state.folders, favorites: state.favorites,
                                           pinnedTabs: state.pinnedTabs + [pin]), deletions: .init())
        try mac.session.saveNow().get()
        return Context(space: space.id.uuidString, folder: folder.id.uuidString, pin: pin.id.uuidString, favorite: favorite.id.uuidString)
    }

    private func expectSane(_ mac: Mac, _ comment: Comment) {
        #expect(Self.isSane(mac.session), comment)
        #expect(mac.controller.isEnabled && mac.controller.canSendRecords && mac.controller.lastError == nil, "\(comment): \(mac.controller.lastError ?? "")")
        #expect(!mac.defaults.bool(forKey: SyncController.applyingKey), comment)
        // The mirror, with every record kind the zone held, reads back at the next launch.
        #expect(!FileManager.default.fileExists(atPath: mac.directory.appendingPathComponent("sync.unreadable.json").path), comment)
    }

    /// The second Mac's first sync finds the records in the zone; or both Macs sync first, and the records come in a later fetch. Either way the second Mac applies them, saves, relaunches, and fetches again without a trap and with a sane sidebar, and the first Mac then takes what the second sent.
    @Test(arguments: Input.allCases, [true, false])
    func recordsFromAnotherMacNeverTrapAndLeaveASaneSidebar(input: Input, firstSync: Bool) async throws {
        guard !firstSync || !input.needsEarlierSync else { return }
        let zone = Zone()
        let a = try Mac(zone: zone), b = try Mac(zone: zone)
        defer { a.clean(); b.clean() }
        let context = try fill(a)
        _ = try fill(b)
        if input == .personaDeletedWhileShown {
            for record in context.shownPersonaRecords { zone.records[record.recordID.recordName] = record }
        }
        await a.controller.setEnabled(true)
        try await a.flush()
        if !firstSync {
            await b.controller.setEnabled(true)
            try await b.flush()
        }
        // A hidden window shows a pin, as the second Mac's window does while the changes apply.
        let shown = try #require(input == .personaDeletedWhileShown ? b.session.tabs.first { $0.id.uuidString == context.shownPersona.pin } : b.session.tabs.first(where: \.isPinned))
        let window = b.session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: try #require(shown.spaceID), selectedTabID: nil, isSidebarVisible: true), kind: .main)
        window.selectTab(shown.id)
        #expect(window.selectedTabID == shown.id)
        let changes = Self.changes(input, in: context)
        for record in changes.records where SyncCloudKitRecords.isInZone(record.recordID) { zone.records[record.recordID.recordName] = record }
        for deletion in changes.deletions { zone.records[deletion.recordID.recordName] = nil }
        zone.pages.append(changes)
        if firstSync { await b.controller.setEnabled(true) } else { await b.controller.refresh() }
        try await b.flush()
        expectSane(b, "\(input) applied")
        #expect(b.session.spaces.contains { $0.id == window.currentSpaceID }, "\(input) window")
        b.session.windowWillClose(window)
        try b.launch()
        #expect(Self.isSane(b.session), "\(input) relaunched")
        await b.controller.refreshIfRequested()
        try await b.flush()
        expectSane(b, "\(input) fetched again")
        await a.controller.refresh()
        try await a.flush()
        expectSane(a, "\(input) on the first Mac")
    }

    /// What the two Macs hold under one ID, as when one Mac's data folder came from the other.
    enum SharedID: String, CaseIterable, Sendable {
        /// A pinned tab on one Mac, an open tab on the other.
        case tab
        /// A pinned folder holding a pin on one Mac, an open folder holding an open tab on the other.
        case folder
    }

    /// One Mac pins a tab or folder whose ID the other Mac's open tab or open folder has, which never syncs. The open item takes a new ID and keeps its page, contents, and window's selection, the pin joins beside it, and neither Mac deletes the pin: when the Mac with the open item finds the pin at its first sync, when it finds it in a later fetch after the pinning Mac's first sync uploads it, and from the pinning Mac's side in both.
    @Test(arguments: SharedID.allCases, [true, false])
    func anOpenItemThatSharesAPinsIDTakesANewIDAndThePinStays(item: SharedID, openMacSyncsFirst: Bool) async throws {
        let zone = Zone()
        let pinning = try Mac(zone: zone), open = try Mac(zone: zone)
        defer { pinning.clean(); open.clean() }
        let shared = UUID(), page = URL(string: "about:blank#open")!
        // The pinning Mac's pin, or its pinned folder with a pin inside.
        let pinSpace = try #require(pinning.session.spaces.first)
        if item == .folder {
            pinning.session.appendFolder(TabFolder(id: shared, spaceID: pinSpace.id, name: "Pinned folder", isPinned: true))
        }
        let pinState = pinning.session.sidebarSyncState
        let pin = SidebarSyncState.PinnedTab(id: item == .tab ? shared : UUID(), personaID: Persona.defaultID, spaceID: pinSpace.id, folderID: item == .folder ? shared : nil,
                                             savedPage: SavedPage(url: URL(string: "about:blank#pin")!, title: "Pin"), customTitle: nil, engine: .webKit)
        pinning.session.applySidebarSync(.init(personas: pinState.personas, spaces: pinState.spaces, folders: pinState.folders, favorites: [], pinnedTabs: [pin]),
                                         deletions: .init())
        try pinning.session.saveNow().get()
        // The other Mac's open tab, or its open folder with an open tab inside, selected in a hidden window.
        let openSpace = try #require(open.session.spaces.first)
        if item == .folder { open.session.appendFolder(TabFolder(id: shared, spaceID: openSpace.id, name: "Open folder", isPinned: false)) }
        let openTab = open.session.adopt(open.session.makeWebContents(url: page, engine: .webKit, state: nil, in: Persona.defaultID), id: item == .tab ? shared : UUID(),
                                         spaceID: openSpace.id, personaID: Persona.defaultID, pinned: false, select: false, folderID: item == .folder ? shared : nil)
        openTab.customTitle = "Open"
        try open.session.saveNow().get()
        let window = open.session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: openSpace.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        window.selectTab(openTab.id)

        if openMacSyncsFirst {
            await open.controller.setEnabled(true)
            try await open.flush()
            await pinning.controller.setEnabled(true)
            try await pinning.flush()
            await open.controller.refresh()
        } else {
            await pinning.controller.setEnabled(true)
            try await pinning.flush()
            await open.controller.setEnabled(true)
        }
        try await open.flush()
        await pinning.controller.refresh()
        try await pinning.flush()

        let name = shared.uuidString
        #expect(zone.records[name] != nil, "the pin's record stays")
        for mac in [pinning, open] {
            expectSane(mac, "\(item)")
            switch item {
            case .tab: #expect(mac.session.tabs.contains { $0.id == shared && $0.isPinned })
            case .folder: #expect(mac.session.folders.contains { $0.id == shared && $0.isPinned })
            }
            #expect(!mac.engine.pendingChanges.contains(.deleteRecord(name)))
        }
        // The open item is the same item under a new ID.
        let kept = try #require(open.session.tabs.first { $0.customTitle == "Open" })
        #expect(kept.id != shared && !kept.isPinned && kept.url == page && window.selectedTabID == kept.id)
        if item == .folder {
            let folder = try #require(open.session.folders.first { $0.name == "Open folder" })
            #expect(folder.id != shared && !folder.isPinned && kept.folderID == folder.id)
        } else {
            #expect(open.session.tabs.filter { $0.id == shared }.count == 1)
        }
        #expect(pinning.session.sidebarSyncState == open.session.sidebarSyncState)
        open.session.windowWillClose(window)
        try open.launch()
        await open.controller.refreshIfRequested()
        try await open.flush()
        expectSane(open, "\(item) relaunched")
        #expect(open.session.tabs.contains { $0.customTitle == "Open" && $0.id != shared } && zone.records[name] != nil)
    }
}
