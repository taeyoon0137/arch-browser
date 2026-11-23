// The explanation kept locally after account or zone loss. Settings chooses the availability
// message first, then this reason when the current account becomes available.
/// A locally saved reason sync was disabled after account or zone loss.
public enum SyncOffReason: String, Sendable {
    case accountChanged
    case zoneDeleted

    /// The Settings message explaining why sync turned off.
    public var message: String {
        switch self {
        case .accountChanged: localized("Sync turned off because the iCloud account changed. Turn it on to merge this Mac’s sidebar into the current account.")
        case .zoneDeleted: localized("Sync turned off because Arch’s iCloud data was deleted. Turn it on to upload this Mac’s sidebar again.")
        }
    }
}
