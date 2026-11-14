// The explanation kept locally after account or zone loss. Settings chooses the availability
// message first, then this reason when the current account becomes available.
public enum SyncOffReason: String, Sendable {
    case accountChanged
    case zoneDeleted

    public var message: String {
        switch self {
        case .accountChanged: "Sync turned off because the iCloud account changed. Turn it on to merge this Mac’s sidebar into the current account."
        case .zoneDeleted: "Sync turned off because Arch’s iCloud data was deleted. Turn it on to upload this Mac’s sidebar again."
        }
    }
}
