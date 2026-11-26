// Per-device open tabs use encrypted payloads separate from the editable sidebar graph.
import Browsing
import CryptoKit
import Foundation

public enum RemoteTabsRecords {
    static let chunkByteLimit = 128 * 1024
    static let heartbeatInterval: TimeInterval = 24 * 60 * 60
    public static let lifetime: TimeInterval = 14 * 24 * 60 * 60

    private struct Payload: Codable {
        var generation: String
        var index: Int
        var count: Int
        var tabs: [RemoteTab]
    }

    static func name(deviceID: String, spaceID: UUID, chunk: Int) -> String {
        "remote-tabs-\(deviceID)-\(spaceID.uuidString)-\(chunk)"
    }

    static func owns(_ record: SyncRecord, deviceID: String) -> Bool {
        guard record.recordType == .remoteTabs, record[.deviceID] == .text(deviceID),
              case .reference(let space) = record[.space], let spaceID = UUID(uuidString: space) else { return false }
        let prefix = name(deviceID: deviceID, spaceID: spaceID, chunk: 0).dropLast()
        guard record.recordName.hasPrefix(prefix), let index = Int(record.recordName.dropFirst(prefix.count)), index >= 0 else { return false }
        return record.recordName == name(deviceID: deviceID, spaceID: spaceID, chunk: index)
    }

    /// Each chunk stays below CloudKit's record limit; all chunks identify the same complete snapshot.
    static func records(from spaces: [OpenTabsSpace], deviceID: String, deviceName: String, at date: Date) -> [SyncRecord] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var seen = Set<UUID>()
        return spaces.filter { seen.insert($0.spaceID).inserted }.flatMap { space -> [SyncRecord] in
            let tabs = space.tabs.filter { valid($0) }.sorted { $0.order < $1.order }
            guard !tabs.isEmpty, let complete = try? encoder.encode(tabs) else { return [] }
            let generation = SHA256.hash(data: complete).map { String(format: "%02x", $0) }.joined()
            var chunks: [[RemoteTab]] = []
            var chunk: [RemoteTab] = []
            var bytes = 512
            for tab in tabs {
                guard let encoded = try? encoder.encode(tab), encoded.count < chunkByteLimit - 512 else { continue }
                if bytes + encoded.count + 1 > chunkByteLimit {
                    chunks.append(chunk); chunk = []; bytes = 512
                }
                chunk.append(tab)
                bytes += encoded.count + 1
            }
            if !chunk.isEmpty { chunks.append(chunk) }
            return chunks.enumerated().compactMap { index, tabs in
                let payload = Payload(generation: generation, index: index, count: chunks.count, tabs: tabs)
                guard let bytes = try? encoder.encode(payload), let text = String(data: bytes, encoding: .utf8) else { return nil }
                let fields: [String: SyncValue] = [
                    "persona": .reference(space.personaID == Persona.defaultID ? "default" : space.personaID.uuidString),
                    "space": .reference(space.spaceID.uuidString), "deviceID": .text(deviceID),
                    "deviceName": .text(String(deviceName.prefix(256))), "tabs": .text(text)
                ]
                return SyncRecord(recordType: .remoteTabs, recordName: name(deviceID: deviceID, spaceID: space.spaceID, chunk: index),
                                  fields: fields, fieldModifiedAt: fields.mapValues { _ in date }, modifiedAt: date)
            }
        }
    }

    private static func valid(_ tab: RemoteTab) -> Bool {
        ["http", "https"].contains(tab.url.scheme?.lowercased() ?? "") && tab.url.host != nil
            && tab.url.user == nil && tab.url.password == nil && tab.order >= 0
    }

    /// Incomplete, stale, malformed snapshots and those over five minutes in the future produce no folder.
    static func groups(from records: [SyncRecord], excluding deviceID: String, at date: Date) -> [RemoteTabGroup] {
        struct Chunk {
            var record: SyncRecord
            var deviceID: String
            var deviceName: String
            var personaID: UUID
            var spaceID: UUID
            var payload: Payload
        }
        let chunks = records.compactMap { record -> Chunk? in
            guard record.recordType == .remoteTabs,
                  date.timeIntervalSince(record.modifiedAt) >= -300,
                  date.timeIntervalSince(record.modifiedAt) < lifetime,
                  case .text(let owner) = record[.deviceID], owner != deviceID,
                  let id = UUID(uuidString: owner), owner == id.uuidString,
                  owns(record, deviceID: owner),
                  case .text(let name) = record[.deviceName], !name.isEmpty, name.count <= 256,
                  case .reference(let persona) = record[.persona],
                  let personaID = persona == "default" ? Persona.defaultID : UUID(uuidString: persona),
                  case .reference(let space) = record[.space], let spaceID = UUID(uuidString: space),
                  case .text(let text) = record[.tabs], text.utf8.count <= chunkByteLimit,
                  let payload = try? JSONDecoder().decode(Payload.self, from: Data(text.utf8)),
                  payload.count > 0, payload.index >= 0, payload.index < payload.count,
                  record.recordName == Self.name(deviceID: owner, spaceID: spaceID, chunk: payload.index),
                  !payload.tabs.isEmpty, payload.tabs.allSatisfy(valid) else { return nil }
            return Chunk(record: record, deviceID: owner, deviceName: name, personaID: personaID, spaceID: spaceID, payload: payload)
        }
        let grouped = Dictionary(grouping: chunks) { "\($0.deviceID)/\($0.spaceID.uuidString)" }
        return grouped.values.compactMap { chunks in
            guard let latest = chunks.max(by: { $0.record.modifiedAt < $1.record.modifiedAt }) else { return nil }
            let parts = chunks.filter { $0.payload.generation == latest.payload.generation }
            guard parts.count == latest.payload.count,
                  Set(parts.map(\.payload.index)).count == latest.payload.count,
                  parts.allSatisfy({ $0.payload.count == latest.payload.count && $0.personaID == latest.personaID && $0.deviceName == latest.deviceName }) else { return nil }
            let tabs = parts.sorted { $0.payload.index < $1.payload.index }.flatMap(\.payload.tabs).sorted { $0.order < $1.order }
            guard Set(tabs.map(\.order)).count == tabs.count else { return nil }
            return RemoteTabGroup(deviceID: latest.deviceID, deviceName: latest.deviceName, personaID: latest.personaID,
                                  spaceID: latest.spaceID, tabs: tabs, updatedAt: parts.map(\.record.modifiedAt).min()!)
        }.sorted { ($0.deviceName, $0.deviceID, $0.spaceID.uuidString) < ($1.deviceName, $1.deviceID, $1.spaceID.uuidString) }
    }
}
