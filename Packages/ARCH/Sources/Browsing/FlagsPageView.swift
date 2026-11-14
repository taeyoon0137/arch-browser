// Internal pages open by address from the command palette and cover the page area until the user closes them, selects a tab, or goes to another address. `flags://` shows the private API flags.
import ARCHPrivateAPI
import SwiftUI

public enum InternalPage {
    case flags

    public var address: String {
        switch self {
        case .flags: return "flags://"
        }
    }

    /// The page's name, which its heading and the window's title show.
    var title: String {
        switch self {
        case .flags: return "Flags"
        }
    }

    /// Accepts the address with or without its slashes.
    init?(address: String) {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["flags://", "flags:", "flags:/"].contains(text) else { return nil }
        self = .flags
    }
}

struct InternalPageView: View {
    let page: InternalPage

    var body: some View {
        switch page {
        case .flags: FlagsPageView(flags: PrivateAPIFlags.shared)
        }
    }
}

/// The switch for all private APIs, then each private API with whether this system has it, then each feature that uses them.
struct FlagsPageView: View {
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @ObservedObject var flags: PrivateAPIFlags

    /// Escape closes the page only while no field above it, such as the palette's or the find bar's, needs Escape.
    private var closesOnEscape: Bool {
        windowModel.commandPaletteMode == nil && !windowModel.isFindBarVisible && windowModel.renamingSpaceID == nil && windowModel.renamingTabID == nil && windowModel.renamingFolderID == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    Text(InternalPage.flags.title)
                        .font(.system(size: 26, weight: .bold))
                    Spacer()
                    Button("Close", action: windowModel.closeInternalPage)
                        .keyboardShortcut(closesOnEscape ? .cancelAction : nil)
                }
                Text("Private APIs are parts of macOS and the engines that are not documented for apps. Arch uses one only while its flags are on and the running system has it; otherwise the feature falls back or stays hidden.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Use private APIs")
                        .accessibilityHidden(true)
                    Spacer()
                    Toggle("Use private APIs", isOn: Binding(get: { flags.allowsPrivateAPIs }, set: { flags.allowsPrivateAPIs = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                FlagsSection(title: "Private APIs", emptyText: "Arch uses no private API yet.", isEmpty: flags.apis.isEmpty) {
                    ForEach(flags.apis) { api in
                        FlagRow(title: api.name, detail: "\(api.framework) · \(availabilityText(api.id))", isMonospaced: true,
                                isOn: Binding(get: { flags.isOn(api: api.id) }, set: { flags.setOn($0, api: api.id) }))
                    }
                }
                .disabled(!flags.allowsPrivateAPIs)
                FlagsSection(title: "Features", emptyText: "No feature uses a private API yet.", isEmpty: flags.features.isEmpty) {
                    ForEach(flags.features) { feature in
                        FlagRow(title: feature.name, detail: featureDetail(feature), isMonospaced: false,
                                isOn: Binding(get: { flags.isOn(feature: feature.id) }, set: { flags.setOn($0, feature: feature.id) }))
                    }
                }
                .disabled(!flags.allowsPrivateAPIs)
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func availabilityText(_ id: String) -> String {
        switch flags.availability[id] {
        case true?: return "Available"
        case false?: return "Missing on this system"
        case nil: return "Checking…"
        }
    }

    private func featureDetail(_ feature: PrivateAPIFeature) -> String {
        let names = feature.apiIDs.map { id in flags.apis.first { $0.id == id }?.name ?? id }.joined(separator: ", ")
        return "\(flags.allows(feature.id) ? "Active" : "Inactive") · Uses \(names)"
    }
}

private struct FlagsSection<Content: View>: View {
    let title: String
    let emptyText: String
    let isEmpty: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            } else {
                content
            }
        }
    }
}

/// The title and detail on the leading side and the switch at the trailing edge, so the switches of all rows form one column, as in Settings.
private struct FlagRow: View {
    let title: String
    let detail: String
    let isMonospaced: Bool
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(isMonospaced ? .system(size: 13, design: .monospaced) : .system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // Dims with the switch while Use private APIs is off, which text beside a control does not do by itself.
            .opacity(isEnabled ? 1 : 0.5)
            // The switch carries the title as its label and the detail as its hint, so VoiceOver reads each row once.
            .accessibilityHidden(true)
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityHint(detail)
        }
    }
}
