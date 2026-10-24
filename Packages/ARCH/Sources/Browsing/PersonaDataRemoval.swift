// A deleted Persona's cookies and website data stay on disk until the next launch, because an engine cannot remove the storage of a profile it has loaded. Data goes only for the IDs that `session.json` lists, never because a Persona is missing.
import ARCHEngine
import Foundation

/// The deleted Personas whose stored data is still on disk, and the pass at launch that has the engines remove it.
final class PersonaDataRemoval {
    /// The engines that keep storage of their own for each Persona. An ID stays listed until each of them has removed its data, also while one is not registered, as when the Chromium framework is missing.
    static let storageEngines: [EngineKind] = [.webKit, .chromium]

    /// The Personas whose data is still to be removed, in the order they were deleted.
    private(set) var pendingIDs: [UUID]
    /// Called after an ID leaves `pendingIDs`.
    var didRemove: (() -> Void)?
    /// The engines that have not yet reported each pending ID's data removed.
    private var remainingEngines: [UUID: Set<EngineKind>] = [:]

    /// Asks every registered engine to remove the data of each ID. Runs before any engine starts.
    init(ids: [UUID], registry: EngineRegistry, configuration: EngineApplicationConfiguration) {
        pendingIDs = ids
        for id in ids {
            remainingEngines[id] = Set(Self.storageEngines)
            for kind in Self.storageEngines {
                registry.engine(for: kind)?.removeStoredData(forStorage: id, configuration: configuration) { [weak self] removed in
                    if removed { self?.engine(kind, didRemoveDataOf: id) }
                }
            }
        }
    }

    private func engine(_ kind: EngineKind, didRemoveDataOf id: UUID) {
        remainingEngines[id]?.remove(kind)
        guard remainingEngines[id]?.isEmpty == true else { return }
        remainingEngines[id] = nil
        pendingIDs.removeAll { $0 == id }
        didRemove?()
    }
}
