// Adapts BrowserSession's saved sidebar to the sync controller's read, apply, and save operations.
import ARCHEngine
import Browsing
import Foundation

/// The session surface used by SyncController. A committed mirror may reference only a sidebar
/// already saved through saveNow(). Tests supply a sidebar and fail its write without CloudKit.
@MainActor public protocol SyncedSidebar: AnyObject {
    var needsFullSidebarSync: Bool { get }
    func finishSidebarSyncRecovery()
    var sidebarSyncState: SidebarSyncState { get }
    /// The engine of an incoming tab whose record names none.
    var defaultEngine: EngineKind { get }
    var onSidebarSyncSave: ((SidebarSyncState) -> Void)? { get set }
    func applySidebarSync(_ state: SidebarSyncState, deletions: SidebarSyncDeletions)
    func applyFirstSidebarSync(_ state: SidebarSyncState, replacements: SidebarSyncReplacements)
    func saveNow() -> Result<Void, Error>
    var openTabsSyncState: [OpenTabsSpace] { get }
    var onOpenTabsSyncSave: (([OpenTabsSpace]) -> Void)? { get set }
    var remoteTabGroups: [RemoteTabGroup] { get set }
    var showRemoteTabs: Bool { get set }
    var onShowRemoteTabsChange: ((Bool) -> Void)? { get set }
}

extension SyncedSidebar {
    public var openTabsSyncState: [OpenTabsSpace] { [] }
    public var onOpenTabsSyncSave: (([OpenTabsSpace]) -> Void)? { get { nil } set {} }
    public var remoteTabGroups: [RemoteTabGroup] { get { [] } set {} }
    public var showRemoteTabs: Bool { get { true } set {} }
    public var onShowRemoteTabsChange: ((Bool) -> Void)? { get { nil } set {} }
}

extension BrowserSession: SyncedSidebar {}
