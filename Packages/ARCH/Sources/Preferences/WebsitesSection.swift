// Settings ▸ Websites lists the sites with remembered permission answers of one Persona, the active window's at first, with a picker for another while several Personas keep answers. The user can change or remove each answer.
// It also shows whether macOS permits Arch to display notifications from sites allowed to send them.
import ARCHEngine
import Browsing
import SwiftUI

/// One group per website with the shown Persona's remembered answers, each with a menu to change it and a button to remove it. With several Personas that keep answers, a picker names the shown Persona alone, since Settings has no space (Persona rule 7), and lists every Persona but the Agents Persona, which remembers none. A website asks again for a permission whose answer is removed. While a website may send notifications and macOS does not let Arch show them, a group at the top says so and offers the way to turn them on.
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
    /// The Personas that keep answers. The section follows only the session's Personas, not every change of the session.
    @State private var personas: [Persona] = []
    @State private var personaID = Persona.defaultID

    var body: some View {
        let personaID = shownPersonaID
        let decisions = store.decisions(in: personaID)
        let origins = decisions.keys.sorted { Self.siteTitle(for: $0).localizedStandardCompare(Self.siteTitle(for: $1)) == .orderedAscending }
        // macOS's permission is the app's, so any Persona's allowed site needs it.
        let hasAllowedSite = store.answers.values.contains { $0.decisions.values.contains { $0[.notifications] == .allow } }
        Form {
            if personas.count > 1 {
                Section {
                    Picker(localized("Persona"), selection: $personaID) {
                        ForEach(personas) { Text($0.name).tag($0.id) }
                    }
                }
            }
            if let notice = Self.notificationNotice(for: notifications.status, hasAllowedSite: hasAllowedSite) {
                Section {
                    noticeRow(notice)
                }
            }
            if origins.isEmpty {
                Section {
                    Text("No remembered permissions", bundle: .module)
                        .foregroundStyle(.secondary)
                } footer: {
                    footer
                }
            }
            ForEach(origins, id: \.self) { origin in
                Section {
                    ForEach(types(of: origin, in: decisions), id: \.self) { type in
                        row(for: type, origin: origin, in: personaID)
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
        // The Agents Persona is named agent-only after it joins the Personas, so the list is read on the next turn.
        .onReceive(session.$personas) { _ in DispatchQueue.main.async { personas = session.personasWithRememberedAnswers } }
        // Each time the section shows, it starts at the active window's Persona.
        .onAppear { self.personaID = session.personaForWebsiteSettings }
    }

    /// The chosen Persona while it keeps answers, else the default one.
    private var shownPersonaID: Persona.ID {
        personas.contains { $0.id == personaID } ? personaID : Persona.defaultID
    }

    private func row(for type: EnginePermissionType, origin: String, in personaID: Persona.ID) -> some View {
        LabeledContent(Self.permissionTitle(for: type)) {
            HStack(spacing: 8) {
                Picker(Self.permissionTitle(for: type), selection: Binding(
                    get: { store.decision(for: type, origin: origin, in: personaID) ?? .deny },
                    set: { decision in
                        store.set(decision, for: [type], origin: origin, in: personaID)
                        // Allowing a website's notifications here asks macOS too, as Allow on the permission card does.
                        if type == .notifications, decision == .allow { notifications.request { _ in } }
                    }
                )) {
                    Text("Allow", bundle: .module).tag(SitePermissionStore.Decision.allow)
                    Text("Don\u{2019}t Allow", bundle: .module).tag(SitePermissionStore.Decision.deny)
                }
                .labelsHidden()
                .accessibilityLabel(Self.permissionTitle(for: type))
                .fixedSize()
                Button {
                    store.set(nil, for: [type], origin: origin, in: personaID)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(localized("Remove"))
                .accessibilityLabel(localized("Remove"))
            }
        }
    }

    @ViewBuilder
    private func noticeRow(_ notice: NotificationNotice) -> some View {
        switch notice {
        case .openSystemSettings:
            LabeledContent {
                Button(localized("Open System Settings")) { notifications.openSystemSettings() }
            } label: {
                Text("Notifications for Arch are off", bundle: .module)
                Text("The websites you allow can\u{2019}t show notifications.", bundle: .module)
            }
        case .turnOn:
            LabeledContent {
                Button(localized("Turn On Notifications\u{2026}")) { notifications.request { _ in } }
            } label: {
                Text("Notifications for Arch aren\u{2019}t turned on", bundle: .module)
                Text("The websites you allow can\u{2019}t show notifications.", bundle: .module)
            }
        }
    }

    private var footer: some View {
        formFootnote(personas.count > 1
            ? localized("Each Persona remembers its own answers when a website asks for a permission such as the camera. A website asks again once you remove its answer. Screen recording always asks. Websites can\u{2019}t show notifications in WebKit tabs.")
            : localized("Arch remembers your answer when a website asks for a permission such as the camera. A website asks again once you remove its answer. Screen recording always asks. Websites can\u{2019}t show notifications in WebKit tabs."))
    }

    /// The origin's permission types in the order of their titles.
    private func types(of origin: String, in decisions: [String: [EnginePermissionType: SitePermissionStore.Decision]]) -> [EnginePermissionType] {
        let types = decisions[origin].map { Array($0.keys) } ?? []
        return types.sorted { Self.permissionTitle(for: $0).localizedStandardCompare(Self.permissionTitle(for: $1)) == .orderedAscending }
    }

    /// An `https` site shows only its host and port; another scheme stays in view.
    private static func siteTitle(for origin: String) -> String {
        origin.hasPrefix("https://") ? String(origin.dropFirst("https://".count)) : origin
    }

    private static func permissionTitle(for type: EnginePermissionType) -> String {
        switch type {
        case .camera: return localized("Camera")
        case .microphone: return localized("Microphone")
        case .screenCapture: return localized("Screen recording")
        case .geolocation: return localized("Location")
        case .notifications: return localized("Notifications")
        case .clipboard: return localized("Clipboard")
        case .midi: return localized("MIDI devices")
        }
    }
}
