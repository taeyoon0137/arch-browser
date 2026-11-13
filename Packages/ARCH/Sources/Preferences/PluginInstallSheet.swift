// The review sheet of a plugin package the user chose to install or update, a web extension's among them, or that AI wrote: its name, version, origin, where it runs and which engines refused it, the permissions and sites it asks for in plain sentences, and its files, with the source of each for a plugin that AI wrote, after the requests it came from. The user can leave sites out before installing, and granting every website or native apps asks for Touch ID or the login password. The subtitle names where the package came from: a file, the Web Store, or AI, and with two or more Personas the review names the Persona it installs in (Persona rule 7 in `docs/windows-personas.md`). A package from the Web Store comes from the store sheet, the sheet's first step, which the review replaces. An update from another place than the installed plugin's comes with a warning, as only the signatures of a `.crx` file prove an identifier and such a package takes over the plugin's data, and an unsigned update of a plugin whose package was signed adds another. A web extension that may be another engine's version of an installed plugin can join it as that version, with a warning when it comes from another place under the plugin's identifier and so takes over the plugin's extension data on that engine, and after a new web extension installs while it asks for another engine's version, the sheet's last step offers that version.
import ARCHEngine
import Browsing
import Extensions
import LocalAuthentication
import Plugins
import SwiftUI

/// What the sheet reviews: a staged package, and, for Install <Engine> Version…, the plugin it joins and the engine it is the version for.
struct PluginReview: Identifiable {
    var id: URL { package.rootURL }
    let package: PluginPackage
    var versionOf: PluginID?
    var engine: EngineKind?
}

/// The store sheet for a package from the Web Store, then the review, then, for a new plugin that asks for another engine's version, the last step, whose Install <Engine> Version… puts that version's review or the store sheet for it in the sheet's place.
struct PluginInstallSheet: View {
    @ObservedObject var plugins: PluginManager
    /// The sentence that names the Persona the package installs in, with two or more Personas.
    private let personaSentence: String?
    /// Stages packages from the Web Store, for the store sheet and From the Web Store….
    private let webStore: WebStoreInstaller?
    /// Takes the user back to the composer of a plugin that AI wrote, to ask for a change.
    private let askForChanges: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step

    /// The sheet's first step.
    enum Start {
        case review(PluginReview)
        /// The store sheet, which stages a package from the Web Store for the review.
        case webStore(WebStoreStart)
    }

    private enum Step {
        case webStore(WebStoreStart)
        case review(PluginReview)
        /// The plugin installed and asks for the engine's version.
        case installed(PluginID, EngineKind)
    }

    /// `webStore` stages the store sheet's packages; a sheet without one starts with a review and offers no package from the Web Store.
    init(plugins: PluginManager, start: Start, personaSentence: String? = nil, webStore: WebStoreInstaller? = nil, askForChanges: (() -> Void)? = nil) {
        self.plugins = plugins
        self.personaSentence = personaSentence
        self.webStore = webStore
        self.askForChanges = askForChanges
        switch start {
        case let .review(review): _step = State(initialValue: .review(review))
        case let .webStore(storeStart): _step = State(initialValue: .webStore(storeStart))
        }
    }

    /// How the review names the Persona from where the install started (Persona rule 7): "Installs in the Persona of “Work / Research” for all its spaces." from a tab or a window, with its space, "Installs in “Work” for all its spaces." from Settings ▸ Plugins, without one, and nil while the default Persona is the only one.
    static func personaSentence(persona: Persona.ID, space: Space?, among personas: [Persona]) -> String? {
        guard let place = BrowserSession.displayedPlace(ofPersona: persona, space: space, among: personas) else { return nil }
        return space == nil ? "Installs in \u{201C}\(place)\u{201D} for all its spaces." : "Installs in the Persona of \u{201C}\(place)\u{201D} for all its spaces."
    }

    var body: some View {
        Group {
            switch step {
            case let .webStore(start):
                if let webStore {
                    WebStoreInstallSheet(plugins: plugins, installer: webStore, start: start, close: { dismiss() }) { step = .review($0) }
                }
            case let .review(review):
                PluginReviewView(plugins: plugins, review: review, personaSentence: personaSentence, askForChanges: askForChanges, close: { dismiss() }) { id, isNewPlugin in
                    if isNewPlugin, let engine = plugins.missingEngine(of: id) {
                        step = .installed(id, engine)
                    } else {
                        dismiss()
                    }
                }
                // A review that takes the last step's place starts with its own sites and choice.
                .id(review.id)
            case let .installed(id, engine):
                VersionLastStep(plugins: plugins, plugin: id, engine: engine, offersWebStore: webStore != nil, close: { dismiss() },
                                review: { step = .review($0) }, storeSheet: { step = .webStore($0) })
            }
        }
        .padding(20)
        // A plugin that AI wrote shows its sources, and the store sheet takes the height of its field and messages.
        .frame(width: isWrittenByAI ? 600 : 480, height: isStoreSheet ? nil : isWrittenByAI ? 640 : 520)
        .interactiveDismissDisabled()
    }

    private var isStoreSheet: Bool {
        guard case .webStore = step else { return false }
        return true
    }

    /// Whether the sheet reviews a plugin that AI wrote.
    private var isWrittenByAI: Bool {
        guard case let .review(review) = step, case .generated = review.package.origin else { return false }
        return true
    }
}

/// The review of one package. For a web extension that matches an installed plugin, the user chooses whether it installs as that plugin's version for an engine or as an update or a separate plugin; for an update of a pair whose versions share the package's identifier, which version it updates.
private struct PluginReviewView: View {
    @ObservedObject var plugins: PluginManager
    let review: PluginReview
    let personaSentence: String?
    let askForChanges: (() -> Void)?
    let close: () -> Void
    /// The installed plugin's identifier, and whether it is a new plugin rather than an update or a version.
    let installed: (PluginID, Bool) -> Void
    @State private var choice: Choice
    @State private var updateTarget: PluginID?
    /// The sites the user grants: at first all that the manifest asks for, except, in an update or a version, those that the installed version asked for and the user left out.
    @State private var sites: Set<MatchPattern>
    /// Why the last install failed.
    @State private var failure: String?

    /// How the package installs: as the plugin's version for an engine, or as an update or a plugin of its own.
    private enum Choice: Hashable {
        case version(EngineKind)
        case plugin
    }

    init(plugins: PluginManager, review: PluginReview, personaSentence: String?, askForChanges: (() -> Void)?, close: @escaping () -> Void,
         installed: @escaping (PluginID, Bool) -> Void) {
        self.plugins = plugins
        self.review = review
        self.personaSentence = personaSentence
        self.askForChanges = askForChanges
        self.close = close
        self.installed = installed
        let choice = (review.engine ?? review.package.suggestedEngine).map(Choice.version) ?? .plugin
        _choice = State(initialValue: choice)
        _updateTarget = State(initialValue: review.package.updates)
        _sites = State(initialValue: Self.offeredSites(review: review, choice: choice, target: review.package.updates, in: plugins))
    }

    private var package: PluginPackage { review.package }

    /// The plugin the package joins as a version for the chosen engine.
    private var joined: InstalledPlugin? {
        guard case .version = choice else { return nil }
        return plugins.plugins.first { $0.id == review.versionOf ?? package.counterpart }
    }

    /// The installed plugin the package updates.
    private var target: InstalledPlugin? {
        guard choice == .plugin, review.versionOf == nil else { return nil }
        return updateTarget.flatMap { id in plugins.plugins.first { $0.id == id } }
    }

    /// The installed plugin the package matches, while the review offers to join it.
    private var match: InstalledPlugin? {
        guard review.versionOf == nil, !package.joinableEngines.isEmpty else { return nil }
        return package.counterpart.flatMap { id in plugins.plugins.first { $0.id == id } }
    }

    /// Why the package cannot install as chosen, after which the review offers Cancel only.
    private var refusal: String? {
        if case let .version(engine) = choice, let id = review.versionOf ?? package.counterpart {
            return plugins.versionRefusal(for: package, joining: id, for: engine)
        }
        return target.flatMap { plugins.updateRefusal(for: package, updating: $0.id) }
    }

    var body: some View {
        let manifest = package.manifest
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text("Version \(manifest.version) \(origin). \(manifest.summary)")
                    .foregroundStyle(.secondary)
                if let personaSentence {
                    Text(personaSentence)
                        .foregroundStyle(.secondary)
                }
                if let note = package.kind.note {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                ForEach(package.engineNotes, id: \.self) { note in
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                if let match, let engine = choiceEngine ?? package.joinableEngines.first {
                    Text("This may be the \(engine.displayName) version of \u{201C}\(name(of: match))\u{201D}, which runs on \(EngineKind.tabsList(match.engines)) tabs. Arch can show the two as one plugin.")
                        .foregroundStyle(.secondary)
                }
                if let target, let warning = otherSourceWarning(for: target) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let target, let warning = package.proofWarning(updating: target) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let target, refusal == nil {
                    let lost = EngineKind.allCases.filter { engine in
                        guard target.engines.contains(engine), case .refused? = package.engineChecks[engine] else { return false }
                        return true
                    }
                    ForEach(lost, id: \.self) { engine in
                        Label("\(engine.displayName) tabs lose \u{201C}\(name(of: target))\u{201D}.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let joined, let engine = choiceEngine, refusal == nil, let takeover = plugins.versionTakeover(for: package, joining: joined.id, for: engine) {
                    Label(takeover, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let joined, review.versionOf != nil, refusal == nil, differsInNameOrDeveloper(from: joined) {
                    Label("Its name or developer differs from \u{201C}\(name(of: joined))\u{201D}. Join only if both come from the same developer.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let refusal {
                    Text(refusal)
                        .foregroundStyle(.red)
                }
            }
            Form {
                if let composition {
                    Section("Requests") {
                        ForEach(composition.requests.indices, id: \.self) { Text(composition.requests[$0]) }
                    }
                }
                if let match {
                    Section {
                        Picker("Install", selection: $choice) {
                            ForEach(package.joinableEngines, id: \.self) { engine in
                                Text("Install as the \(engine.displayName) Version").tag(Choice.version(engine))
                            }
                            Text(package.updates == match.id ? "Update \u{201C}\(name(of: match))\u{201D}" : "Install as a Separate Plugin").tag(Choice.plugin)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                }
                if choice == .plugin, package.updateChoices.count > 1 {
                    Section {
                        Picker("Update", selection: $updateTarget) {
                            ForEach(package.updateChoices, id: \.self) { id in
                                Text(versionTitle(of: id)).tag(Optional(id))
                            }
                        }
                    }
                }
                Section("Access") {
                    let permissions = PluginPermission.allCases.filter(manifest.permissions.contains)
                    if permissions.isEmpty && manifest.sites.isEmpty && manifest.extensionPermissions.isEmpty {
                        Text("None")
                    }
                    ForEach(permissions, id: \.self) { permission in
                        RequestRow(text: permission.summary, isNew: target.map { !$0.manifest.permissions.contains(permission) } ?? false)
                    }
                    if let summary = manifest.extensionPermissionsSummary {
                        RequestRow(text: summary, isNew: target.map { !Set(manifest.extensionPermissions).isSubset(of: $0.manifest.extensionPermissions) } ?? false)
                    }
                    ForEach(manifest.sites, id: \.self) { site in
                        Toggle(isOn: Binding(get: { sites.contains(site) }, set: { if $0 { sites.insert(site) } else { sites.remove(site) } })) {
                            RequestRow(text: site.accessSummary, isNew: target.map { !$0.manifest.sites.contains(site) } ?? false)
                            Text(site.description)
                        }
                    }
                }
                Section("Files") {
                    ForEach(package.files, id: \.self) { path in
                        if composition == nil {
                            Text(path).font(.system(.body, design: .monospaced))
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(path).font(.system(.body, design: .monospaced).weight(.semibold))
                                Text(package.text(of: path) ?? "")
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
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
                Button("Cancel", role: .cancel) {
                    plugins.discard(package)
                    close()
                }
                .keyboardShortcut(.cancelAction)
                if let askForChanges {
                    Button("Ask for Changes\u{2026}", action: askForChanges)
                }
                if refusal == nil {
                    if let joined {
                        // A version installs on or off as the plugin it joins is.
                        Button("Install") { install(isEnabled: joined.isEnabled) }
                            .keyboardShortcut(.defaultAction)
                    } else if let target {
                        Button("Update") { install(isEnabled: target.isEnabled) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Install") { install(isEnabled: false) }
                        Button("Install and Enable") { install(isEnabled: true) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .onChange(of: choice) { sites = Self.offeredSites(review: review, choice: choice, target: updateTarget, in: plugins) }
        .onChange(of: updateTarget) { sites = Self.offeredSites(review: review, choice: choice, target: updateTarget, in: plugins) }
    }

    /// The engine of the chosen version, if the choice is one.
    private var choiceEngine: EngineKind? {
        guard case let .version(engine) = choice else { return nil }
        return engine
    }

    private var title: String {
        let name = package.manifest.name
        if let joined, let engine = choiceEngine { return "Install the \(engine.displayName) Version of \u{201C}\(self.name(of: joined))\u{201D}?" }
        if let target {
            guard let engine = target.pairEngine else { return "Update \u{201C}\(name)\u{201D}?" }
            return "Update the \(engine.displayName) Version of \u{201C}\(self.name(of: target))\u{201D}?"
        }
        return "Install \u{201C}\(name)\u{201D}?"
    }

    /// The name of the plugin, or of the pair it is a version of.
    private func name(of plugin: InstalledPlugin) -> String {
        plugins.leadVersion(of: plugin.id)?.manifest.name ?? plugin.manifest.name
    }

    /// "The Chromium Version", for a version of a pair, or the plugin's name.
    private func versionTitle(of id: PluginID) -> String {
        guard let plugin = plugins.plugins.first(where: { $0.id == id }) else { return id.rawValue }
        return plugin.pairEngine.map { "The \($0.displayName) Version" } ?? plugin.manifest.name
    }

    /// How AI wrote the package, if it did.
    private var composition: PluginComposition? {
        guard case let .generated(composition) = package.origin else { return nil }
        return composition
    }

    /// Where the package came from, as the subtitle says it.
    private var origin: String {
        switch package.origin {
        case .bundled: return "built into Arch"
        case let .file(url): return "from \(url.lastPathComponent)"
        case .webStore: return "from the Web Store"
        case let .generated(composition): return "written by AI with \(composition.model)"
        }
    }

    /// The warning for a package that updates the installed plugin from another place: another file than the one it was installed from, or a file for a plugin that AI wrote.
    private func otherSourceWarning(for installed: InstalledPlugin) -> String? {
        let replaces = "This package replaces \u{201C}\(name(of: installed))\u{201D}"
        switch (installed.origin, package.origin) {
        case let (.file(source), .file(packageSource)) where packageSource.standardizedFileURL.path == source.standardizedFileURL.path:
            return nil
        case let (.file(source), _):
            return "\(replaces), which you installed from \(source.lastPathComponent), and takes over its data. Update only if both come from the same developer."
        case (.generated, .file):
            return "\(replaces), which AI wrote, and takes over its data. Update only if you made this package from it."
        default:
            return nil
        }
    }

    /// Whether the package's name, compared without case and spaces at either end, or a developer field that both manifests give differs from the plugin's.
    private func differsInNameOrDeveloper(from plugin: InstalledPlugin) -> Bool {
        let trimmed = { (name: String) in name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let manifest = package.manifest
        return trimmed(manifest.name) != trimmed(plugin.manifest.name) || [(manifest.author, plugin.manifest.author), (manifest.homepage, plugin.manifest.homepage)].contains { pair in
            guard let mine = pair.0, let theirs = pair.1 else { return false }
            return mine != theirs
        }
    }

    /// The sites the review offers at first: for an update, or a version, as an update of the installed plugin would offer them; otherwise all that the manifest asks for.
    private static func offeredSites(review: PluginReview, choice: Choice, target: PluginID?, in plugins: PluginManager) -> Set<MatchPattern> {
        let manifest = review.package.manifest
        var installedID = review.versionOf == nil ? target : nil
        if case .version = choice { installedID = review.versionOf ?? review.package.counterpart }
        let installed = installedID.flatMap { id in plugins.plugins.first { $0.id == id } }
        return Set((installed.map { PluginGrant(updating: $0, to: manifest) } ?? PluginGrant(requestedBy: manifest)).sites)
    }

    /// Installs with every permission the manifest asks for and the chosen sites, once the user confirms a grant of every website or of native apps.
    private func install(isEnabled: Bool) {
        var package = package
        package.updates = target?.id
        let grant = PluginGrant(permissions: package.manifest.permissions, sites: package.manifest.sites.filter(sites.contains))
        let version = joined?.id
        let engine = choiceEngine
        let isNewPlugin = version == nil && target == nil
        Task {
            if let reason = grant.confirmationReason(for: package.manifest.name) {
                guard await Self.authorize(reason) else { return }
            }
            do {
                installed(try plugins.install(package, grant: grant, isEnabled: isEnabled, asVersionOf: version, for: engine), isNewPlugin)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Touch ID or the login password through LocalAuthentication.
    private static func authorize(_ reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// The install sheet's last step for a new plugin that asks for another engine's version: the note, Install <Engine> Version…, which reviews the chosen package in the sheet's place or, with From the Web Store…, puts the store sheet there, Don't Ask Again, which dismisses the note for the engine, and Done, which leaves the note in Settings and on the engine's tabs.
private struct VersionLastStep: View {
    @ObservedObject var plugins: PluginManager
    let plugin: PluginID
    let engine: EngineKind
    /// Whether Install <Engine> Version… offers From the Web Store….
    let offersWebStore: Bool
    let close: () -> Void
    let review: (PluginReview) -> Void
    let storeSheet: (WebStoreStart) -> Void
    /// Why the chosen package could not be staged.
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let installed = plugins.plugins.first(where: { $0.id == plugin }) {
                Text("\u{201C}\(installed.manifest.name)\u{201D} is installed.")
                    .font(.headline)
                Text(versionNote(for: installed, engine: engine))
                    .foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
            }
            Spacer()
            HStack {
                Button("Don\u{2019}t Ask Again") {
                    plugins.dismissVersionNote(of: plugin, for: engine)
                    close()
                }
                Spacer()
                InstallVersionMenu(engine: engine, offersWebStore: offersWebStore) { source in
                    guard let installed = plugins.plugins.first(where: { $0.id == plugin }) else { return }
                    guard source == .file else { return storeSheet(WebStoreStart(versionOf: plugin, engine: engine)) }
                    chooseVersionPackage(of: installed, for: engine, in: plugins, over: NSApp.keyWindow) { result in
                        switch result {
                        case let .success(package)?: review(PluginReview(package: package, versionOf: plugin, engine: engine))
                        case let .failure(error)?: failure = error.localizedDescription
                        case nil: break
                        }
                    }
                }
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The note of a plugin that asks for the engine's version, such as "It runs on WebKit tabs. Its developer may offer a separate version for Chromium; install it to use “Reader” on Chromium tabs too."
func versionNote(for plugin: InstalledPlugin, engine: EngineKind) -> String {
    "It runs on \(EngineKind.tabsList(plugin.engines)) tabs. Its developer may offer a separate version for \(engine.displayName); install it to use \u{201C}\(plugin.manifest.name)\u{201D} on \(engine.displayName) tabs too."
}

/// Where Install <Engine> Version… takes the version's package from.
enum PackageSource {
    /// A folder or file that the open panel chooses.
    case file
    /// The store sheet.
    case webStore
}

/// Install <Engine> Version…: a menu with From a File… and From the Web Store…, or a button for the file alone without the store.
struct InstallVersionMenu: View {
    let engine: EngineKind
    var offersWebStore = true
    let choose: (PackageSource) -> Void

    var body: some View {
        let title = "Install \(engine.displayName) Version\u{2026}"
        if offersWebStore {
            Menu(title) {
                Button("From a File\u{2026}") { choose(.file) }
                Button("From the Web Store\u{2026}") { choose(.webStore) }
            }
            .fixedSize()
        } else {
            Button(title) { choose(.file) }
        }
    }
}

/// Asks with an open panel over `window` for the package of the plugin's version for the engine, of the engine's package types, and stages it. `staged` gets nil when the user cancels the panel.
@MainActor
func chooseVersionPackage(of plugin: InstalledPlugin, for engine: EngineKind, in plugins: PluginManager, over window: NSWindow?,
                          staged: @escaping (Result<PluginPackage, any Error>?) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowedContentTypes = plugins.packageTypes(forVersionOf: plugin.id, for: engine)
    panel.message = "Choose the \(engine.displayName) version of \u{201C}\(plugins.leadVersion(of: plugin.id)?.manifest.name ?? plugin.manifest.name)\u{201D}."
    panel.prompt = "Review"
    let finish = { (response: NSApplication.ModalResponse) in
        guard response == .OK, let url = panel.url else { return staged(nil) }
        Task {
            do {
                staged(.success(try await plugins.stage(url)))
            } catch {
                staged(.failure(error))
            }
        }
    }
    if let window {
        panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
        panel.begin(completionHandler: finish)
    }
}

extension EngineKind {
    /// The engines' names as a sentence lists them, in the order of `EngineKind`, such as "WebKit and Chromium".
    static func tabsList(_ engines: Set<EngineKind>) -> String {
        let names = allCases.filter(engines.contains).map(\.displayName)
        guard let last = names.last else { return "no" }
        return names.count < 3 ? names.joined(separator: " and ") : names.dropLast().joined(separator: ", ") + ", and " + last
    }
}

/// One thing the plugin asks for, marked when an update asks for it and the installed version did not.
private struct RequestRow: View {
    let text: String
    let isNew: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            if isNew {
                Text("New")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
        }
    }
}
