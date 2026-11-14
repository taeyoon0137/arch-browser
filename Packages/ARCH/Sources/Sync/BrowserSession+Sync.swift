import Browsing
import Foundation

/// The session surface used by SyncController. A committed mirror may reference only a sidebar
/// already saved through saveNow(). Tests supply a sidebar and fail its write without CloudKit.
@MainActor public protocol SyncedSidebar: AnyObject {
    var needsFullSidebarSync: Bool { get }
    func finishSidebarSyncRecovery()
    var sidebarSyncState: SidebarSyncState { get }
    var onSidebarSyncSave: ((SidebarSyncState) -> Void)? { get set }
    func applySidebarSync(_ state: SidebarSyncState, deletions: SidebarSyncDeletions)
    func applyFirstSidebarSync(_ state: SidebarSyncState, replacements: SidebarSyncReplacements)
    func saveNow() -> Result<Void, Error>
}

extension BrowserSession: SyncedSidebar {}
