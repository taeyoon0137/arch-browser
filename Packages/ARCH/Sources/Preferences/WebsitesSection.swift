// The Websites section of Settings: each website with a remembered permission answer, where the user changes or removes the answer.
import ARCHEngine
import Browsing
import SwiftUI

/// One group per website with its remembered answers, each with a menu to change it and a button to remove it. A website asks again for a permission whose answer is removed.
struct WebsitesSection: View {
    /// The session's remembered answers.
    @ObservedObject var store: SitePermissionStore

    var body: some View {
        let origins = store.decisions.keys.sorted { Self.siteTitle(for: $0).localizedStandardCompare(Self.siteTitle(for: $1)) == .orderedAscending }
        Form {
            if origins.isEmpty {
                Section {
                    Text("No remembered permissions")
                        .foregroundStyle(.secondary)
                } footer: {
                    footer
                }
            }
            ForEach(origins, id: \.self) { origin in
                Section {
                    ForEach(types(of: origin), id: \.self) { type in
                        row(for: type, origin: origin)
                    }
                } header: {
                    Text(Self.siteTitle(for: origin))
                } footer: {
                    if origin == origins.last { footer }
                }
            }
        }
        .formStyle(.grouped)
        // A fixed height keeps the window still while answers come and go; the list scrolls instead.
        .frame(width: sectionWidth, height: 360)
    }

    private func row(for type: EnginePermissionType, origin: String) -> some View {
        LabeledContent(Self.permissionTitle(for: type)) {
            HStack(spacing: 8) {
                Picker(Self.permissionTitle(for: type), selection: Binding(
                    get: { store.decision(for: type, origin: origin) ?? .deny },
                    set: { store.set($0, for: [type], origin: origin) }
                )) {
                    Text("Allow").tag(SitePermissionStore.Decision.allow)
                    Text("Don\u{2019}t Allow").tag(SitePermissionStore.Decision.deny)
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    store.set(nil, for: [type], origin: origin)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove")
                .accessibilityLabel("Remove")
            }
        }
    }

    private var footer: some View {
        // A grouped form's footer is trailing-aligned and primary by default.
        Text("Arch remembers your answer when a website asks for a permission such as the camera. A website asks again once you remove its answer. Screen recording always asks.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The origin's permission types in the order of their titles.
    private func types(of origin: String) -> [EnginePermissionType] {
        let types = store.decisions[origin].map { Array($0.keys) } ?? []
        return types.sorted { Self.permissionTitle(for: $0).localizedStandardCompare(Self.permissionTitle(for: $1)) == .orderedAscending }
    }

    /// An `https` site shows only its host and port; another scheme stays in view.
    private static func siteTitle(for origin: String) -> String {
        origin.hasPrefix("https://") ? String(origin.dropFirst("https://".count)) : origin
    }

    private static func permissionTitle(for type: EnginePermissionType) -> String {
        switch type {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .screenCapture: return "Screen recording"
        case .geolocation: return "Location"
        case .notifications: return "Notifications"
        case .clipboard: return "Clipboard"
        case .midi: return "MIDI devices"
        }
    }
}
