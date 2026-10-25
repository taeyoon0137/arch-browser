// Settings ▸ Plugins: the plugins of each Persona, each with its switch, what its grant lets it do, and its settings as a form. Only built-in plugins exist so far, which keep the grant their manifests ask for, so the section states the grant without controls to narrow it.
import Browsing
import Plugins
import SwiftUI

/// With two or more Personas, a picker chooses whose plugins the section shows. The list scrolls in a section of fixed height.
struct PluginsSection: View {
    let session: BrowserSession
    /// The session's Personas. The section follows only them, not every change of the session.
    @State private var personas: [Persona] = []
    @State private var personaID = Persona.defaultID

    var body: some View {
        Form {
            if personas.count > 1 {
                Section {
                    Picker("Persona", selection: $personaID) {
                        ForEach(personas) { Text($0.name).tag($0.id) }
                    }
                }
            }
            PluginList(session: session, plugins: session.plugins(in: shownPersonaID), personaID: shownPersonaID)
        }
        .formStyle(.grouped)
        .frame(width: sectionWidth, height: 440)
        .onReceive(session.$personas) { personas = $0 }
    }

    /// The chosen Persona while it exists, else the default one.
    private var shownPersonaID: Persona.ID {
        personas.contains { $0.id == personaID } ? personaID : Persona.defaultID
    }
}

/// One section per plugin, in the order the manager registered them.
private struct PluginList: View {
    let session: BrowserSession
    @ObservedObject var plugins: PluginManager
    let personaID: Persona.ID

    var body: some View {
        ForEach(plugins.plugins) { plugin in
            PluginSection(session: session, plugins: plugins, personaID: personaID, plugin: plugin)
        }
    }
}

/// The plugin's switch with its summary, its grant, its settings, which work while it is on, and Reload Matching Tabs for a plugin with page scripts, which start with each page's next load.
private struct PluginSection: View {
    let session: BrowserSession
    @ObservedObject var plugins: PluginManager
    let personaID: Persona.ID
    let plugin: InstalledPlugin
    /// Why the last change to a setting failed.
    @State private var failure: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { plugin.isEnabled }, set: { plugins.setEnabled($0, for: plugin.id) })) {
                Text(plugin.manifest.name)
                Text(plugin.manifest.summary)
            }
            LabeledContent("Access") {
                let summaries = plugin.grant.summaries
                Text(summaries.isEmpty ? "None" : summaries.joined(separator: "\n"))
                    .multilineTextAlignment(.trailing)
            }
            ForEach(plugin.manifest.contributions.settings) { setting in
                PluginSettingRow(plugins: plugins, plugin: plugin.id, setting: setting) { failure = $0.localizedDescription }
            }
            .disabled(!plugin.isEnabled)
            if plugin.isEnabled, !plugin.manifest.contributions.pageScripts.isEmpty {
                Button("Reload Matching Tabs") { session.reloadTabs(coveredByPageScriptsOf: plugin.id, in: personaID) }
            }
        } footer: {
            // A grouped form's footer is trailing-aligned and primary by default.
            VStack(alignment: .leading, spacing: 4) {
                Text("Version \(plugin.manifest.version), built into Arch.")
                    .foregroundStyle(.secondary)
                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A field of the plugin's form. A number stays within the setting's range, and a secret goes to the Keychain.
private struct PluginSettingRow: View {
    @ObservedObject var plugins: PluginManager
    let plugin: PluginID
    let setting: PluginSetting
    let onFailure: (Error) -> Void

    var body: some View {
        switch setting.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { value == .bool(true) }, set: { write(.bool($0)) })) { title }
        case .text:
            TextField(text: Binding(get: { text }, set: { write(.string($0)) })) { title }
        case let .number(_, range):
            TextField(value: Binding(get: { number }, set: { write(.number(range.map($0.clamped) ?? $0)) }), format: .number) { title }
        case let .choice(_, options):
            Picker(selection: Binding(get: { text }, set: { write(.string($0)) })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            } label: {
                title
            }
        case .secret:
            PluginSecretRow(plugins: plugins, plugin: plugin, setting: setting, onFailure: onFailure) { title }
        }
    }

    @ViewBuilder private var title: some View {
        Text(setting.title)
        if let help = setting.help { Text(help) }
    }

    private var value: PluginValue? { plugins.value(of: setting, for: plugin) }

    private var text: String {
        if case let .string(text)? = value { return text }
        return ""
    }

    private var number: Double {
        if case let .number(number)? = value { return number }
        return 0
    }

    private func write(_ value: PluginValue) {
        do {
            try plugins.setValue(value, of: setting, for: plugin)
        } catch {
            onFailure(error)
        }
    }
}

/// A secure field whose value goes to the Keychain on Save. The field never shows the saved value; it says whether one is saved, and Remove deletes it.
private struct PluginSecretRow<Title: View>: View {
    @ObservedObject var plugins: PluginManager
    let plugin: PluginID
    let setting: PluginSetting
    let onFailure: (Error) -> Void
    @ViewBuilder let title: Title
    @State private var draft = ""

    var body: some View {
        let isSaved = (try? plugins.hasSecret(setting, for: plugin)) == true
        LabeledContent {
            HStack(spacing: 6) {
                SecureField("Secret", text: $draft, prompt: Text(isSaved ? "Saved" : "Not Set"))
                    .labelsHidden()
                    .frame(width: 160)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(draft.isEmpty)
                if isSaved {
                    Button("Remove") { write(nil) }
                }
            }
        } label: {
            title
        }
    }

    private func save() {
        guard !draft.isEmpty else { return }
        write(draft)
        draft = ""
    }

    private func write(_ secret: String?) {
        do {
            try plugins.setSecret(secret, of: setting, for: plugin)
        } catch {
            onFailure(error)
        }
    }
}

private extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
