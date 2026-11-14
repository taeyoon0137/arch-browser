// Settings ▸ Sync uses only the account state and controls of this Mac's sync controller.
import SwiftUI
import Sync

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
            account = checking ? "Checking…" : "Not checked"
            explanation = checking ? nil : "Turn on sync to check this Mac’s iCloud account."
        } else {
            switch availability {
            case .unavailable(let reason):
                canPause = enabled && !checking && !deleting
                isOn = false
                canToggle = false
                canDelete = false
                account = "Unavailable"
                explanation = reason.message
            case .available:
                canPause = false
                isOn = enabled
                canToggle = !checking && !deleting
                canDelete = enabled && !checking && !deleting
                account = "Available"
                explanation = offReason?.message
            }
        }
    }
}

struct SyncSection: View {
    @ObservedObject var controller: SyncController
    @State private var confirmsDeletion = false

    var body: some View {
        let state = SyncSectionState(availability: controller.availability, checked: controller.hasCheckedAvailability,
                                     checking: controller.isCheckingAvailability, enabled: controller.isEnabled,
                                     deleting: controller.isDeletingCloudData, offReason: controller.offReason)
        Form {
            Section {
                Toggle("Sync with iCloud", isOn: Binding(get: { state.isOn }, set: { value in
                    Task { await controller.setEnabled(value) }
                }))
                .disabled(!state.canToggle)
                Text("Personas, spaces, favorites, pinned tabs and their folders, and some settings. Open tabs, history, and website data stay on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("iCloud account", value: state.account)
                if let explanation = state.explanation { Text(explanation).foregroundStyle(.secondary) }
                if state.canPause {
                    Button("Turn Off Sync on This Mac") { Task { await controller.setEnabled(false) } }
                }
                if let date = controller.lastSync {
                    LabeledContent("Last completed sync") { Text(date, format: .dateTime) }
                } else {
                    LabeledContent("Last completed sync", value: "Never")
                }
                if let message = controller.lastError { LabeledContent("Sync status", value: message) }
            }
            Section {
                Button("Delete iCloud Data…", role: .destructive) { confirmsDeletion = true }
                    .disabled(!state.canDelete)
                    .confirmationDialog("Delete Arch’s iCloud Data?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
                        Button("Delete iCloud Data", role: .destructive) { Task { await controller.deleteCloudData() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes Arch’s synced data from iCloud and turns off sync on your Macs. Each Mac keeps its local sidebar and settings.")
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: sectionWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}
