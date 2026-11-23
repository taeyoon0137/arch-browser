// Settings ▸ Sync uses only the account state and controls of this Mac's sync controller.
import SwiftUI
import Sync

/// What Settings ▸ Sync shows and allows, worked out from the sync controller's state.
struct SyncSectionState: Equatable {
    let isOn: Bool
    let canToggle: Bool
    let canDelete: Bool
    let account: String
    let explanation: String?
    let canPause: Bool

    init(availability: SyncAvailability.Status, checked: Bool, checking: Bool, enabled: Bool,
         deleting: Bool, offReason: SyncOffReason?) {
        if !checked {
            canPause = false
            isOn = false
            canToggle = !checking
            canDelete = false
            account = checking ? localized("Checking…") : localized("Not checked")
            explanation = checking ? nil : localized("Turn on sync to check this Mac’s iCloud account.")
        } else {
            switch availability {
            case .unavailable(let reason):
                canPause = enabled && !checking && !deleting
                isOn = false
                canToggle = false
                canDelete = false
                account = localized("Unavailable")
                explanation = reason.message
            case .available:
                canPause = false
                isOn = enabled
                canToggle = !checking && !deleting
                canDelete = enabled && !checking && !deleting
                account = localized("Available")
                explanation = offReason?.message
            }
        }
    }
}

/// Settings ▸ Sync: the iCloud sync switch, the account's state, and the deletion of the cloud data.
struct SyncSection: View {
    @ObservedObject var controller: SyncController
    @State private var confirmsDeletion = false

    var body: some View {
        let state = SyncSectionState(availability: controller.availability, checked: controller.hasCheckedAvailability,
                                     checking: controller.isCheckingAvailability, enabled: controller.isEnabled,
                                     deleting: controller.isDeletingCloudData, offReason: controller.offReason)
        Form {
            Section {
                Toggle(localized("Sync with iCloud"), isOn: Binding(get: { state.isOn }, set: { value in
                    Task { await controller.setEnabled(value) }
                }))
                .disabled(!state.canToggle)
                Text("Personas, spaces, favorites, pinned tabs and their folders, and some settings. Open tabs, history, and website data stay on this Mac.", bundle: .module)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(localized("iCloud account"), value: state.account)
                if let explanation = state.explanation { Text(explanation).foregroundStyle(.secondary) }
                if state.canPause {
                    Button(localized("Turn Off Sync on This Mac")) { Task { await controller.setEnabled(false) } }
                }
                if let date = controller.lastSync {
                    LabeledContent(localized("Last completed sync")) { Text(date, format: .dateTime) }
                } else {
                    LabeledContent(localized("Last completed sync"), value: localized("Never"))
                }
                if let message = controller.lastError { LabeledContent(localized("Sync status"), value: message) }
            }
            Section {
                Button(localized("Delete iCloud Data…"), role: .destructive) { confirmsDeletion = true }
                    .disabled(!state.canDelete)
                    .confirmationDialog(localized("Delete Arch’s iCloud Data?"), isPresented: $confirmsDeletion, titleVisibility: .visible) {
                        Button(localized("Delete iCloud Data"), role: .destructive) { Task { await controller.deleteCloudData() } }
                        Button(localized("Cancel"), role: .cancel) {}
                    } message: {
                        Text("This removes Arch’s synced data from iCloud and turns off sync on your Macs. Each Mac keeps its local sidebar and settings.", bundle: .module)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: sectionWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}
