import AppKit
import Browsing
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Preferences

@MainActor @Suite struct SyncSectionTests {
    private let database = SyncDatabase(containerIdentifier: "fixture.test", environment: "Development")

    @Test func theFirstOptInAndCheckedAccountStatesOfferOnlyAvailableActions() {
        func state(_ status: SyncAvailability.Status, checked: Bool = true, checking: Bool = false, enabled: Bool = false,
                   deleting: Bool = false, reason: SyncOffReason? = nil) -> SyncSectionState {
            SyncSectionState(availability: status, checked: checked, checking: checking, enabled: enabled, deleting: deleting, offReason: reason)
        }
        let initial = state(.unavailable(.temporarilyUnavailable), checked: false)
        #expect(initial.canToggle && !initial.isOn && !initial.canDelete && initial.account == "Not checked")
        #expect(!state(.available(database), checked: false, checking: true).canToggle)
        for reason in [SyncAvailability.Reason.notSignedForICloud, .noAccount, .restricted, .temporarilyUnavailable] {
            let result = state(.unavailable(reason), enabled: true, reason: .accountChanged)
            #expect(!result.canToggle && !result.isOn && !result.canDelete && result.explanation == reason.message)
            #expect(result.canPause && !state(.unavailable(reason)).canPause)
        }
        let afterAccountChange = state(.available(database), reason: .accountChanged)
        #expect(afterAccountChange.canToggle && !afterAccountChange.isOn && !afterAccountChange.canDelete)
        #expect(afterAccountChange.explanation == SyncOffReason.accountChanged.message)
        #expect(state(.available(database), reason: .zoneDeleted).explanation == SyncOffReason.zoneDeleted.message)
        let on = state(.available(database), enabled: true)
        #expect(on.canToggle && on.isOn && on.canDelete && on.explanation == nil)
        let deleting = state(.available(database), enabled: true, deleting: true)
        #expect(!deleting.canToggle && deleting.isOn && !deleting.canDelete)
    }

    private final class Sidebar: SyncedSidebar {
        let needsFullSidebarSync = false
        func finishSidebarSyncRecovery() {}
        var onSidebarSyncSave: ((SidebarSyncState) -> Void)?
        var sidebarSyncState: SidebarSyncState { .init(personas: [], spaces: [], folders: [], favorites: [], pinnedTabs: []) }
        func applyFirstSidebarSync(_ state: SidebarSyncState, replacements: SidebarSyncReplacements) { Issue.record("Unexpected sync") }
        func applySidebarSync(_ state: SidebarSyncState, deletions: SidebarSyncDeletions) { Issue.record("Unexpected sync") }
        func saveNow() -> Result<Void, Error> { Issue.record("Unexpected session save"); return .success(()) }
    }

    @Test func anUnentitledBuildRendersTheNativeSettingsSectionWithoutStartingSync() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = SyncController(sidebar: Sidebar(), directory: directory, defaults: defaults)
        try #require(controller.availability == .unavailable(.notSignedForICloud))
        let host = NSHostingController(rootView: SyncSection(controller: controller))
        let window = NSWindow(contentViewController: host)
        window.contentView?.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        #expect(size.width == sectionWidth && size.height > 140)
        #expect(!window.isVisible && !controller.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
