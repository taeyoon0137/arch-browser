// Settings ▸ Plugins: the plugins of each Persona, web extensions among them, each with its switch, what its grant lets it do, and its settings as a form; Install Plugin…, which stages a folder, a `.zip` archive, or a `.crx` file and shows its review sheet; and, while a provider can serve it, New Feature with AI…, where AI writes a plugin for the review sheet. Installed plugins can be removed. The section states each grant without controls to narrow it. Two web extension plugins that are versions of one extension show as one section with a row for each version; an unpaired web extension plugin offers Join With… and Install <Engine> Version….
import AI
import ARCHEngine
import Browsing
import Plugins
import SwiftUI
import UniformTypeIdentifiers

/// A request to show a plugin in Settings ▸ Plugins with the open panel for its version for an engine, from the site settings popover.
struct PluginVersionRequest: Equatable {
    let persona: Persona.ID
    let plugin: PluginID
    let engine: EngineKind
}

/// The request Settings ▸ Plugins has yet to answer, which the Settings window sets.
@MainActor
final class PluginVersionRequests: ObservableObject {
    static let shared = PluginVersionRequests()
    @Published var pending: PluginVersionRequest?
}

/// With two or more Personas, a picker chooses whose plugins the section shows. The list scrolls in a section of fixed height.
struct PluginsSection: View {
    let session: BrowserSession
    /// The session's Personas. The section follows only them, not every change of the session.
    @State private var personas: [Persona] = []
    @State private var personaID = Persona.defaultID

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if personas.count > 1 {
                    Section {
                        Picker("Persona", selection: $personaID) {
                            ForEach(personas) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                // Each Persona's list is a view of its own, so that a review sheet open while the user deletes its Persona closes instead of installing into the Persona shown next.
                PluginList(session: session, plugins: session.plugins(in: shownPersonaID), personaID: shownPersonaID, proxy: proxy)
                    .id(shownPersonaID)
            }
            .formStyle(.grouped)
        }
        .frame(width: sectionWidth, height: 440)
        .onReceive(session.$personas) { personas = $0 }
        // A request for another Persona's plugin shows that Persona, whose list then answers it.
        .onReceive(PluginVersionRequests.shared.$pending) { request in
            if let request, request.persona != personaID, session.personas.contains(where: { $0.id == request.persona }) { personaID = request.persona }
        }
    }

    /// The chosen Persona while it exists, else the default one.
    private var shownPersonaID: Persona.ID {
        personas.contains { $0.id == personaID } ? personaID : Persona.defaultID
    }
}

/// Install Plugin… and New Feature with AI…, then one section per plugin, in the order the manager registered them, a pair once at the place of its version installed first.
private struct PluginList: View {
    let session: BrowserSession
    @ObservedObject var plugins: PluginManager
    let personaID: Persona.ID
    let proxy: ScrollViewProxy
    /// The providers and routes, which decide whether AI can write plugins.
    @ObservedObject private var aiSettings = AIService.shared.settings
    /// The package under review.
    @State private var staged: PluginReview?
    /// Whether the sheet of New Feature with AI shows.
    @State private var isComposing = false
    /// Why the last chosen folder or archive could not be staged.
    @State private var failure: String?

    var body: some View {
        Section {
            LabeledContent("Install a plugin or a web extension from a folder, a .zip archive, or a .crx file") {
                Button("Install Plugin…", action: choosePackage)
            }
            if AIService.shared.isAvailable(.pluginComposer) {
                LabeledContent("Describe a feature, and AI writes a plugin for it") {
                    Button("New Feature with AI\u{2026}") { isComposing = true }
                }
                .sheet(isPresented: $isComposing) { PluginComposerSheet(plugins: plugins) }
            }
        } footer: {
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $staged) { PluginInstallSheet(plugins: plugins, review: $0) }
        .onReceive(PluginVersionRequests.shared.$pending) { request in
            guard let request, request.persona == personaID, let plugin = plugins.leadVersion(of: request.plugin) else { return }
            // After the window shows the section, and outside the request's own publishing.
            DispatchQueue.main.async {
                PluginVersionRequests.shared.pending = nil
                proxy.scrollTo(plugin.id, anchor: .top)
                installVersion(of: plugin, for: request.engine)
            }
        }
        ForEach(plugins.plugins.filter { plugins.leadVersion(of: $0.id)?.id == $0.id }) { plugin in
            PluginSection(session: session, plugins: plugins, personaID: personaID, plugin: plugin, installVersion: installVersion)
                .id(plugin.id)
        }
    }

    /// Install <Engine> Version…: asks for the package with an open panel on the Settings window, then reviews it as the plugin's version for the engine.
    private func installVersion(of plugin: InstalledPlugin, for engine: EngineKind) {
        chooseVersionPackage(of: plugin, for: engine, in: plugins, over: PreferencesWindowController.shared.window) { result in
            switch result {
            case let .success(package):
                staged = PluginReview(package: package, versionOf: plugin.id, engine: engine)
                failure = nil
            case let .failure(error):
                failure = error.localizedDescription
            }
        }
    }

    /// Asks for a package with an open panel on the Settings window, then stages it for the review sheet.
    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.folder, .zip, PluginPackage.crxType]
        panel.prompt = "Review"
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    staged = PluginReview(package: try await plugins.stage(url))
                    failure = nil
                } catch {
                    failure = error.localizedDescription
                }
            }
        }
        if let window = PreferencesWindowController.shared.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

/// The plugin's switch with its summary, its grant, its settings, which work while it is on, Reload Matching Tabs for a plugin with page scripts, which start with each page's next load, and Remove… for an installed plugin. An unpaired web extension plugin adds Install <Engine> Version… for each engine that runs extensions while the plugin runs on another, and Join With… while another unpaired one is installed and every engine that a pair divides runs web extensions on this Mac. A pair has one switch for both versions, a row for each version with its access, where it runs, why it is off or could not start, and Remove Version…, Separate Versions unless its versions share an identifier, and Remove…, which removes both. The footer says where the plugin came from, on which engines' tabs a web extension runs, why the plugin cannot run on this Mac, if it cannot, why the manager switched it off, if it did, while it is on, why it could not start on an engine, and, while it asks for another engine's version, the note with Install <Engine> Version… and Dismiss.
private struct PluginSection: View {
    let session: BrowserSession
    @ObservedObject var plugins: PluginManager
    let personaID: Persona.ID
    let plugin: InstalledPlugin
    let installVersion: (InstalledPlugin, EngineKind) -> Void
    /// Why the last change to a setting, the removal, or a separation failed.
    @State private var failure: String?
    @State private var isConfirmingRemoval = false
    @State private var isJoining = false
    /// The version whose removal the user confirms.
    @State private var removingVersion: InstalledPlugin?

    /// The pair's versions in the order of `EngineKind`, or the plugin alone.
    private var versions: [InstalledPlugin] {
        guard let counterpart = plugin.counterpart.flatMap({ id in plugins.plugins.first { $0.id == id } }) else { return [plugin] }
        let order = { (plugin: InstalledPlugin) in plugin.pairEngine.flatMap { EngineKind.allCases.firstIndex(of: $0) } ?? -1 }
        return [plugin, counterpart].sorted { order($0) < order($1) }
    }

    var body: some View {
        let isPair = plugin.counterpart != nil
        let missingEngine = plugins.missingEngine(of: plugin.id)
        let joinCandidates = plugins.joinCandidates(of: plugin.id)
        Section {
            Toggle(isOn: Binding(get: { versions.contains(where: \.isEnabled) }, set: { plugins.setEnabled($0, for: plugin.id) })) {
                Text(plugin.manifest.name)
                Text(plugin.manifest.summary)
            }
            if isPair {
                ForEach(versions) { version in
                    VersionRow(plugins: plugins, version: version) { removingVersion = version }
                }
            } else {
                AccessRow(plugin: plugin)
            }
            ForEach(plugin.manifest.contributions.settings) { setting in
                PluginSettingRow(plugins: plugins, plugin: plugin.id, setting: setting) { failure = $0.localizedDescription }
            }
            .disabled(!plugin.isEnabled)
            if plugin.isEnabled, !plugin.manifest.contributions.pageScripts.isEmpty {
                Button("Reload Matching Tabs") { session.reloadTabs(coveredByPageScriptsOf: plugin.id, in: personaID) }
            }
            if !isPair, plugin.kind == .webExtension {
                ForEach(plugins.versionEngines(of: plugin.id).filter { $0 != missingEngine }, id: \.self) { engine in
                    Button("Install \(engine.displayName) Version\u{2026}") { installVersion(plugin, engine) }
                }
                if !joinCandidates.isEmpty {
                    Button("Join With\u{2026}") { isJoining = true }
                        .sheet(isPresented: $isJoining) { JoinSheet(plugins: plugins, plugin: plugin, candidates: joinCandidates) }
                }
            }
            if let counterpart = versions.first(where: { $0.id != plugin.id }), counterpart.manifest.id != plugin.manifest.id {
                Button("Separate Versions") {
                    do {
                        try plugins.separate(plugin.id)
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }
            if plugin.origin != .bundled {
                Button("Remove\u{2026}", role: .destructive) { isConfirmingRemoval = true }
                    .confirmationDialog("Remove \u{201C}\(plugin.manifest.name)\u{201D}?", isPresented: $isConfirmingRemoval) {
                        Button("Remove", role: .destructive, action: remove)
                    } message: {
                        Text(isPair ? "Both versions' files, storage, and saved secrets in this Persona are deleted." : "Its files, storage, and saved secrets in this Persona are deleted.")
                    }
            }
        } footer: {
            // A grouped form's footer is trailing-aligned and primary by default.
            VStack(alignment: .leading, spacing: 4) {
                if !isPair {
                    Text("Version \(plugin.manifest.version), \(origin(of: plugin)).")
                        .foregroundStyle(.secondary)
                }
                if let note = plugin.kind.note {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                if !isPair, let note = plugin.enginesNote {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                if let reason = plugin.unavailability {
                    Text(reason)
                        .foregroundStyle(.red)
                }
                if !isPair {
                    FailureNotes(plugin: plugin)
                }
                if let missingEngine {
                    Text(versionNote(for: plugin, engine: missingEngine))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Install \(missingEngine.displayName) Version\u{2026}") { installVersion(plugin, missingEngine) }
                        Button("Dismiss") { plugins.dismissVersionNote(of: plugin.id, for: missingEngine) }
                    }
                }
                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(removingVersion.map { "Remove the \($0.pairEngine?.displayName ?? "") Version of \u{201C}\(plugin.manifest.name)\u{201D}?" } ?? "",
                            isPresented: Binding(get: { removingVersion != nil }, set: { if !$0 { removingVersion = nil } })) {
            Button("Remove Version", role: .destructive) {
                guard let version = removingVersion else { return }
                remove([version.id])
            }
        } message: {
            Text("Its files, storage, and saved secrets in this Persona are deleted. The other version stays installed.")
        }
    }

    /// Removes every version, the one installed first last, so that a failure leaves the plugin in its place.
    private func remove() {
        remove(versions.filter { $0.id != plugin.id }.map(\.id) + [plugin.id])
    }

    private func remove(_ ids: [PluginID]) {
        do {
            for id in ids { try plugins.remove(id) }
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// What the plugin's grant lets it do.
private struct AccessRow: View {
    let plugin: InstalledPlugin

    var body: some View {
        LabeledContent("Access") {
            let summaries = plugin.accessSummaries
            Text(summaries.isEmpty ? "None" : summaries.joined(separator: "\n"))
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Why the manager switched the plugin off, if it did, and, while it is on, why it could not start on an engine.
private struct FailureNotes: View {
    let plugin: InstalledPlugin

    var body: some View {
        if let reason = plugin.failure {
            Text(reason)
                .foregroundStyle(.red)
        }
        // A plugin that failed on every engine is off, and its failure says why.
        if plugin.isEnabled {
            ForEach(EngineKind.allCases.compactMap { plugin.engineFailures[$0] }, id: \.self) { reason in
                Text(reason)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// One version of a pair: its engine, its version and origin, where it runs or why it does not, its access, and Remove Version….
private struct VersionRow: View {
    @ObservedObject var plugins: PluginManager
    let version: InstalledPlugin
    let remove: () -> Void

    var body: some View {
        LabeledContent {
            Button("Remove Version\u{2026}", action: remove)
        } label: {
            Text("\(version.pairEngine?.displayName ?? "") Version")
            Text(["Version \(version.manifest.version), \(origin(of: version)).", plugins.enginesNote(of: version.id)].compactMap { $0 }.joined(separator: " "))
        }
        AccessRow(plugin: version)
        VStack(alignment: .leading, spacing: 4) {
            FailureNotes(plugin: version)
        }
        .font(.callout)
    }
}

/// Join With…: the other unpaired web extension plugin, and which of the two runs on each engine, which starts as `PluginManager.proposedJoin(of:with:)` gives it.
private struct JoinSheet: View {
    @ObservedObject var plugins: PluginManager
    let plugin: InstalledPlugin
    let candidates: [InstalledPlugin]
    @Environment(\.dismiss) private var dismiss
    @State private var other: PluginID
    @State private var versions: [EngineKind: PluginID]
    /// Why the join failed.
    @State private var failure: String?

    init(plugins: PluginManager, plugin: InstalledPlugin, candidates: [InstalledPlugin]) {
        self.plugins = plugins
        self.plugin = plugin
        self.candidates = candidates
        let other = candidates.first?.id ?? plugin.id
        _other = State(initialValue: other)
        _versions = State(initialValue: plugins.proposedJoin(of: plugin.id, with: other)?.versions ?? [:])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join \u{201C}\(plugin.manifest.name)\u{201D} With Another Plugin")
                .font(.headline)
            Text("Arch shows the two as one plugin with a version for each engine, and each engine runs only its version. Each version keeps its own access and storage.")
                .foregroundStyle(.secondary)
            Form {
                Picker("Other plugin", selection: $other) {
                    ForEach(candidates) { Text(title(of: $0)).tag($0.id) }
                }
                ForEach(PluginEngineVersions.engines, id: \.self) { engine in
                    Picker("\(engine.displayName) version", selection: Binding(get: { versions[engine] ?? plugin.id }, set: { versions[engine] = $0 })) {
                        ForEach([plugin] + candidates.filter { $0.id == other }) { Text(title(of: $0)).tag($0.id) }
                    }
                }
            }
            .formStyle(.grouped)
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Join") {
                    do {
                        try plugins.join(PluginEngineVersions(versions))
                        dismiss()
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: other) { versions = plugins.proposedJoin(of: plugin.id, with: $1)?.versions ?? [:] }
    }

    /// The plugin's name with its version and where it came from, so that two plugins of one name differ.
    private func title(of plugin: InstalledPlugin) -> String {
        guard case let .file(url) = plugin.origin else { return plugin.manifest.name }
        return "\(plugin.manifest.name) \(plugin.manifest.version) (\(url.lastPathComponent))"
    }
}

/// Where the plugin came from, as its footer or row says it.
private func origin(of plugin: InstalledPlugin) -> String {
    let installDate = plugin.installedAt.map { " on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
    switch plugin.origin {
    case .bundled:
        return "built into Arch"
    case let .file(url):
        return "installed from \(url.lastPathComponent)\(installDate)"
    case let .generated(composition):
        return "written by AI with \(composition.model)\(installDate) from \(composition.requests.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", then "))"
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

extension PluginKind {
    /// What Settings and the install sheet say about plugins of the kind, if anything, before where the plugin runs.
    var note: String? {
        self == .webExtension ? "A web extension." : nil
    }
}

private extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
