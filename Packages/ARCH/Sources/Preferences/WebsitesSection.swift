// Settings ▸ Websites lists sites with remembered permission answers. The user can change or remove each answer.
// It also shows whether macOS permits Arch to display notifications from sites allowed to send them.
import ARCHEngine
import Browsing
import SwiftUI

/// One group per website with its remembered answers, each with a menu to change it and a button to remove it. A website asks again for a permission whose answer is removed. While a website may send notifications and macOS does not let Arch show them, a group at the top says so and offers the way to turn them on.
struct WebsitesSection: View {
    /// The session's remembered answers.
    @ObservedObject var store: SitePermissionStore
    /// Arch's notification permission from macOS, which websites allowed to send notifications need too. It is read again whenever Arch becomes active, as after a visit to System Settings.
    @ObservedObject var notifications: NotificationAuthorization

    /// What the group at the top offers for Arch's notification permission.
    enum NotificationNotice: Equatable {
        /// Notifications for Arch are off, which only System Settings changes.
        case openSystemSettings
        /// macOS has not asked yet, so Arch can ask.
        case turnOn
    }

    /// The group shows only while a website may send notifications that macOS would not show. A build without its app bundle shows none, since nothing in it can turn notifications on.
    static func notificationNotice(for status: NotificationAuthorization.Status, hasAllowedSite: Bool) -> NotificationNotice? {
        guard hasAllowedSite else { return nil }
        switch status {
        case .denied: return .openSystemSettings
        case .notDetermined: return .turnOn
        case .allowed, .unavailable: return nil
        }
    }

    let session: BrowserSession
    /// Whether a remembered answer holds in several Personas. The section follows only the session's Personas, not every change of the session.
    @State private var hasSeveralPersonas = false

    var body: some View {
        let origins = store.decisions.keys.sorted { Self.siteTitle(for: $0).localizedStandardCompare(Self.siteTitle(for: $1)) == .orderedAscending }
        let hasAllowedSite = store.decisions.values.contains { $0[.notifications] == .allow }
        Form {
            if let notice = Self.notificationNotice(for: notifications.status, hasAllowedSite: hasAllowedSite) {
                Section {
                    noticeRow(notice)
                }
            }
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
        // The Agents Persona is named agent-only after it joins the Personas, so the flag is read on the next turn.
        .onReceive(session.$personas) { _ in DispatchQueue.main.async { hasSeveralPersonas = session.remembersAnswersInSeveralPersonas } }
    }

    private func row(for type: EnginePermissionType, origin: String) -> some View {
        LabeledContent(Self.permissionTitle(for: type)) {
            HStack(spacing: 8) {
                Picker(Self.permissionTitle(for: type), selection: Binding(
                    get: { store.decision(for: type, origin: origin) ?? .deny },
                    set: { decision in
                        store.set(decision, for: [type], origin: origin)
                        // Allowing a website's notifications here asks macOS too, as Allow on the permission card does.
                        if type == .notifications, decision == .allow { notifications.request { _ in } }
                    }
                )) {
                    Text("Allow").tag(SitePermissionStore.Decision.allow)
                    Text("Don\u{2019}t Allow").tag(SitePermissionStore.Decision.deny)
                }
                .labelsHidden()
                .accessibilityLabel(Self.permissionTitle(for: type))
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

    @ViewBuilder
    private func noticeRow(_ notice: NotificationNotice) -> some View {
        switch notice {
        case .openSystemSettings:
            LabeledContent {
                Button("Open System Settings") { notifications.openSystemSettings() }
            } label: {
                Text("Notifications for Arch are off")
                Text("The websites you allow can\u{2019}t show notifications.")
            }
        case .turnOn:
            LabeledContent {
                Button("Turn On Notifications\u{2026}") { notifications.request { _ in } }
            } label: {
                Text("Notifications for Arch aren\u{2019}t turned on")
                Text("The websites you allow can\u{2019}t show notifications.")
            }
        }
    }

    private var footer: some View {
        formFootnote("Arch remembers your answer\(hasSeveralPersonas ? " in every Persona" : "") when a website asks for a permission such as the camera. A website asks again once you remove its answer. Screen recording always asks. Websites can\u{2019}t show notifications in WebKit tabs.")
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
