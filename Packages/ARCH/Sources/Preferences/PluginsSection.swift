// Settings ▸ Plugins: the plugins of each Persona, web extensions among them, each with its switch, what its grant lets it do, and its settings as a form; Install Plugin…, which stages a folder, a `.zip` archive, or a `.crx` file and shows its review sheet; Install from the Web Store…, whose store sheet stages an extension's package from the Web Store for the review; Check for Updates while the Persona has extensions installed from the store, which the section also runs once per Persona per run as it shows the Persona, with when it checked or why it failed, and in each such plugin's section a newer version with Review Update…; and, while a provider can serve it, New Feature with AI…, where AI writes a plugin for the review sheet. Installed plugins can be removed. A write of `plugins.json` that failed shows why, with Try Again. The section states each grant without controls to narrow it. Two web extension plugins that are versions of one extension show as one section with a row for each version; an unpaired web extension plugin offers Join With… and Install <Engine> Version…, a menu with From a File… and From the Web Store…. A web extension that may reach native apps lists them with what they need of Arch (`NativeAppGuide`).
import AI
import ARCHEngine
import Browsing
import Extensions
import Plugins
import SwiftUI
import UniformTypeIdentifiers

/// A request to Settings ▸ Plugins from a tab or a window, which the Settings window sets: the open panel for a plugin's version for an engine, from the site settings popover, or the store sheet started for an extension, from a store page or the palette. The review names the Persona with `space`, the tab's or the window's (Persona rule 7 in `docs/windows-personas.md`).
struct PluginsRequest: Equatable {
    enum Action: Equatable {
        case installVersion(PluginID, EngineKind)
        case installFromWebStore(String)
    }

    let persona: Persona.ID
    let space: Space.ID?
    let action: Action
}

/// The request Settings ▸ Plugins has yet to answer, which the Settings window sets.
@MainActor
final class PluginsRequests: ObservableObject {
    static let shared = PluginsRequests()
    @Published var pending: PluginsRequest?
}

/// With two or more Personas, a picker chooses whose plugins the section shows. The list scrolls in a section of fixed height.
struct PluginsSection: View {
    let session: BrowserSession
    /// The session's Personas. The section follows only them, not every change of the session.
    @State private var personas: [Persona] = []
    @State private var personaID = Persona.defaultID
    /// Whether the shown list is busy (`PluginList.isBusy`), which a request for another Persona waits for.
    @State private var listIsBusy = false

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
                PluginList(session: session, plugins: session.plugins(in: shownPersonaID), personaID: shownPersonaID, proxy: proxy, listIsBusy: $listIsBusy)
                    .id(shownPersonaID)
            }
            .formStyle(.grouped)
        }
        // The AI section's height, so that the review sheet, 520 points tall, stays within the window.
        .frame(width: sectionWidth, height: 540)
        .onReceive(session.$personas) { personas = $0 }
        // The publisher sends a request before `pending` holds it.
        .onReceive(PluginsRequests.shared.$pending) { showPersona(of: $0) }
        .onChange(of: listIsBusy) { showPersona(of: PluginsRequests.shared.pending) }
    }

    /// Shows the Persona of a request for another one, whose list then answers it, once the shown list is not busy, so that switching lists closes none of its sheets.
    private func showPersona(of request: PluginsRequest?) {
        guard let request, request.persona != personaID, !listIsBusy, session.personas.contains(where: { $0.id == request.persona }) else { return }
        personaID = request.persona
    }

    /// The chosen Persona while it exists, else the default one.
    private var shownPersonaID: Persona.ID {
        personas.contains { $0.id == personaID } ? personaID : Persona.defaultID
    }
}

/// Install Plugin…, Install from the Web Store…, Check for Updates while the Persona has store installs, and New Feature with AI…, with why the plugin list could not be saved and Try Again while `plugins.json` lacks changes of the run, then one section per plugin, in the order the manager registered them, a pair once at the place of its version installed first.
private struct PluginList: View {
    let session: BrowserSession
    @ObservedObject var plugins: PluginManager
    let personaID: Persona.ID
    let proxy: ScrollViewProxy
    /// The section's copy of `isBusy`.
    @Binding var listIsBusy: Bool
    /// The providers and routes, which decide whether AI can write plugins.
    @ObservedObject private var aiSettings = AIService.shared.settings
    /// The install sheet: a staged package's review, or the store sheet.
    @State private var sheet: InstallSheet?
    /// Whether the sheet of New Feature with AI shows.
    @State private var isComposing = false
    /// Whether an open panel shows or the package it chose is staging, whose review would replace a sheet shown meanwhile.
    @State private var isChoosing = false
    /// Why the last chosen folder or archive could not be staged.
    @State private var failure: String?

    /// Whether a sheet of the list shows, or an open panel or its staging is under way, which a request waits for.
    private var isBusy: Bool { sheet != nil || isComposing || isChoosing }

    /// How the install sheet starts, with the sentence of its review that names the Persona.
    private struct InstallSheet: Identifiable {
        let id = UUID()
        let start: PluginInstallSheet.Start
        let personaSentence: String?
    }

    var body: some View {
        Section {
            LabeledContent {
                HStack {
                    Button("Install Plugin…", action: choosePackage)
                    Button("Install from the Web Store\u{2026}") { showSheet(.webStore(WebStoreStart()), space: nil) }
                }
            } label: {
                Text("Plugins and web extensions")
                Text("Install one from a folder, a .zip archive, a .crx file, or the Web Store.")
            }
            if WebStoreInstaller.hasStoreInstalls(among: plugins.plugins) {
                UpdateCheckRow(webStore: session.webStore, plugins: plugins)
            }
            if AIService.shared.isAvailable(.pluginComposer) {
                LabeledContent {
                    Button("New Feature with AI\u{2026}") { isComposing = true }
                } label: {
                    Text("Describe a feature, and AI writes a plugin for it")
                    Text("Uses the models chosen for Plugin Writer in Settings \u{25B8} AI.")
                }
                .sheet(isPresented: $isComposing) {
                    PluginComposerSheet(plugins: plugins, personaSentence: PluginInstallSheet.personaSentence(persona: personaID, space: nil, among: session.personas))
                }
            }
        } footer: {
            if failure != nil || plugins.listWriteFailure != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let failure {
                        Text(failure)
                            .foregroundStyle(.red)
                    }
                    if let listFailure = plugins.listWriteFailure {
                        Text(listFailure)
                            .foregroundStyle(.red)
                        Button("Try Again") { plugins.writeListAgain() }
                    }
                }
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $sheet) { sheet in
            PluginInstallSheet(plugins: plugins, start: sheet.start, personaSentence: sheet.personaSentence, webStore: session.webStore)
        }
        // Each Persona's list is a view of its own, so this runs as the section first shows the Persona, which the installer checks once in the run. The installer records the outcome, which `UpdateCheckRow` shows.
        .onAppear {
            Task { try? await session.webStore.checkForUpdates(in: plugins, onlyOncePerRun: true) }
        }
        // A request waits while the list is busy. The publisher sends a request before `pending` holds it.
        .onReceive(PluginsRequests.shared.$pending) { answer($0) }
        .onChange(of: isBusy, initial: true) { listIsBusy = $1 }
        .onChange(of: isBusy) { answer(PluginsRequests.shared.pending) }
        ForEach(plugins.plugins.filter { plugins.leadVersion(of: $0.id)?.id == $0.id }) { plugin in
            PluginSection(session: session, plugins: plugins, personaID: personaID, plugin: plugin, reviewUpdate: reviewUpdate(of:)) { installVersion(of: $0, for: $1, from: $2, space: nil) }
                .id(plugin.id)
        }
    }

    /// Answers a pending request for this Persona once the list is not busy: the version's open panel at its plugin, or the store sheet started for its extension.
    private func answer(_ request: PluginsRequest?) {
        guard let request, request.persona == personaID, !isBusy else { return }
        // After the window shows the section, and outside the request's own publishing.
        DispatchQueue.main.async {
            guard PluginsRequests.shared.pending == request, !isBusy else { return }
            PluginsRequests.shared.pending = nil
            switch request.action {
            case let .installVersion(id, engine):
                guard let plugin = plugins.leadVersion(of: id) else { return }
                proxy.scrollTo(plugin.id, anchor: .top)
                installVersion(of: plugin, for: engine, from: .file, space: request.space)
            case let .installFromWebStore(id):
                showSheet(.webStore(WebStoreStart(text: id, startsAtOnce: true)), space: request.space)
            }
        }
    }

    /// Shows the install sheet, whose review names the Persona with `space`, the tab's or the window's for a request, or alone for a start in this section.
    private func showSheet(_ start: PluginInstallSheet.Start, space: Space.ID?) {
        let space = space.flatMap { id in session.spaces.first { $0.id == id } }
        sheet = InstallSheet(start: start, personaSentence: PluginInstallSheet.personaSentence(persona: personaID, space: space, among: session.personas))
        failure = nil
    }

    /// Review Update…: the store sheet downloads the update that the last check found and puts its review in its place.
    private func reviewUpdate(of plugin: PluginID) {
        showSheet(.webStore(WebStoreStart(update: plugin, startsAtOnce: true)), space: nil)
    }

    /// Install <Engine> Version…: asks for the package with an open panel on the Settings window, or in the store sheet, then reviews it as the plugin's version for the engine.
    private func installVersion(of plugin: InstalledPlugin, for engine: EngineKind, from source: PackageSource, space: Space.ID?) {
        guard source == .file else { return showSheet(.webStore(WebStoreStart(versionOf: plugin.id, engine: engine)), space: space) }
        isChoosing = true
        chooseVersionPackage(of: plugin, for: engine, in: plugins, over: PreferencesWindowController.shared.window) { result in
            switch result {
            case let .success(package)?:
                showSheet(.review(PluginReview(package: package, versionOf: plugin.id, engine: engine)), space: space)
            case let .failure(error)?:
                failure = error.localizedDescription
            case nil:
                break
            }
            isChoosing = false
        }
    }

    /// Asks for a package with an open panel on the Settings window, then stages it for the review sheet.
    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.folder, .zip, PluginPackage.crxType]
        panel.prompt = "Review"
        isChoosing = true
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else {
                isChoosing = false
                return
            }
            Task {
                do {
                    showSheet(.review(PluginReview(package: try await plugins.stage(url))), space: nil)
                } catch {
                    failure = error.localizedDescription
                }
                isChoosing = false
            }
        }
        if let window = PreferencesWindowController.shared.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

/// The plugin's switch with its summary, its grant, a newer version from the Web Store with Review Update…, its settings, which work while it is on, Reload Matching Tabs for a plugin with page scripts, which start with each page's next load, and Remove… for an installed plugin. An unpaired web extension plugin adds Install <Engine> Version…, a menu with From a File… and From the Web Store…, for each engine that runs extensions but not the plugin while the plugin runs on another, and Join With… while another unpaired one is installed and every engine that a pair divides runs web extensions on this Mac. A pair has one switch for both versions, a row for each version with its access, where it runs, why it is off or could not start, and Remove Version…, Separate Versions unless its versions share an identifier, and Remove…, which removes both. The footer says where the plugin came from, on which engines' tabs a web extension runs, why the plugin cannot run on this Mac, if it cannot, why the manager switched it off, if it did, while it is on, why it could not start on an engine, for a web extension whose grant has `nativeMessaging`, its native app lines, and, while it asks for another engine's version, the note with Install <Engine> Version… and Dismiss.
private struct PluginSection: View {
    let session: BrowserSession
    @ObservedObject var plugins: PluginManager
    let personaID: Persona.ID
    let plugin: InstalledPlugin
    /// Review Update… of the plugin or of a version of the pair.
    let reviewUpdate: (PluginID) -> Void
    let installVersion: (InstalledPlugin, EngineKind, PackageSource) -> Void
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
        let reloadable = plugin.isEnabled && !plugin.manifest.contributions.pageScripts.isEmpty
        let versionEngines = !isPair && plugin.kind == .webExtension ? plugins.versionEngines(of: plugin.id).filter { $0 != missingEngine } : []
        let canJoin = !isPair && plugin.kind == .webExtension && !joinCandidates.isEmpty
        let separable = versions.first { $0.id != plugin.id }.map { $0.manifest.id != plugin.manifest.id } ?? false
        let removable = plugin.origin != .bundled
        Section {
            Toggle(isOn: Binding(get: { versions.contains(where: \.isEnabled) }, set: { plugins.setEnabled($0, for: plugin.id) })) {
                Text(plugin.manifest.name)
                Text(plugin.manifest.summary)
            }
            if isPair {
                ForEach(versions) { version in
                    VersionRow(plugins: plugins, version: version) { removingVersion = version }
                    UpdateRow(webStore: session.webStore, plugins: plugins, plugin: version) { reviewUpdate(version.id) }
                }
            } else {
                AccessRow(plugin: plugin)
                UpdateRow(webStore: session.webStore, plugins: plugins, plugin: plugin) { reviewUpdate(plugin.id) }
            }
            ForEach(plugin.manifest.contributions.settings) { setting in
                PluginSettingRow(plugins: plugins, plugin: plugin.id, setting: setting) { failure = $0.localizedDescription }
            }
            .disabled(!plugin.isEnabled)
            // The plugin's commands share one row at its trailing end, as the AI pages' commands do, each at its whole title, and those that do not fit continue on a line below. The row shows only with a command, since an empty one would still take a row in the form.
            if reloadable || !versionEngines.isEmpty || canJoin || separable || removable {
                CommandRowLayout {
                    if reloadable {
                        Button("Reload Matching Tabs") { session.reloadTabs(coveredByPageScriptsOf: plugin.id, in: personaID) }
                    }
                    ForEach(versionEngines, id: \.self) { engine in
                        InstallVersionMenu(engine: engine) { installVersion(plugin, engine, $0) }
                    }
                    if canJoin {
                        Button("Join With\u{2026}") { isJoining = true }
                            .sheet(isPresented: $isJoining) { JoinSheet(plugins: plugins, plugin: plugin, candidates: joinCandidates) }
                    }
                    if separable {
                        Button("Separate Versions") {
                            do {
                                try plugins.separate(plugin.id)
                            } catch {
                                failure = error.localizedDescription
                            }
                        }
                    }
                    if removable {
                        Button("Remove\u{2026}", role: .destructive) { isConfirmingRemoval = true }
                            .confirmationDialog("Remove \u{201C}\(plugin.manifest.name)\u{201D}?", isPresented: $isConfirmingRemoval) {
                                Button("Remove", role: .destructive, action: remove)
                            } message: {
                                Text(isPair ? "Both versions\u{2019} files, storage, and saved secrets in this Persona are deleted." : "Its files, storage, and saved secrets in this Persona are deleted.")
                            }
                    }
                }
            }
        } footer: {
            // A grouped form's footer is trailing-aligned, primary, and sometimes cut to one line by default.
            VStack(alignment: .leading, spacing: 4) {
                if !isPair {
                    Text("Version \(plugin.manifest.version), \(origin(of: plugin)).")
                        .foregroundStyle(.secondary)
                }
                if let note = plugin.kind.note {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                if let note = plugin.aiNote {
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
                if NativeAppGuide.applies(to: versions), let outcomes = session.webExtensions(in: personaID)?.nativeAppOutcomes {
                    NativeAppNotes(links: session.nativeMessagingHosts, outcomes: outcomes, versions: versions)
                }
                if let missingEngine {
                    Text(versionNote(for: plugin, engine: missingEngine))
                        .foregroundStyle(.secondary)
                    HStack {
                        InstallVersionMenu(engine: missingEngine) { installVersion(plugin, missingEngine, $0) }
                        Button("Dismiss") { plugins.dismissVersionNote(of: plugin.id, for: missingEngine) }
                    }
                }
                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                }
            }
            .font(.callout)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
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

/// The commands of a plugin's row at the row's trailing end, each at its ideal width, so that no title is cut, with the system's spacing between neighbors as an `HStack` gives it; a command that does not fit after the others on a line starts the next line, also at the trailing end.
private struct CommandRowLayout: Layout {
    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(of: subviews, within: proposal.width)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacings(between: lines, of: subviews).reduce(0, +)
        return CGSize(width: proposal.width ?? lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = lines(of: subviews, within: bounds.width)
        let spacings = lineSpacings(between: lines, of: subviews) + [0]
        var y = bounds.minY
        for (line, spacing) in zip(lines, spacings) {
            var x = bounds.maxX - line.width
            for (position, index) in line.indices.enumerated() {
                if position > 0 { x += subviews[line.indices[position - 1]].spacing.distance(to: subviews[index].spacing, along: .horizontal) }
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += line.height + spacing
        }
    }

    /// The commands in lines of at most `width`, in their order.
    private func lines(of subviews: Subviews, within width: CGFloat?) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let spacing = line.indices.last.map { subviews[$0].spacing.distance(to: subviews[index].spacing, along: .horizontal) } ?? 0
            if let width, !line.indices.isEmpty, line.width + spacing + size.width > width {
                lines.append(line)
                line = Line()
            }
            line.width += (line.indices.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }

    /// The system's spacing between each line and the next, from the first command of each.
    private func lineSpacings(between lines: [Line], of subviews: Subviews) -> [CGFloat] {
        zip(lines, lines.dropFirst()).map { above, below in
            subviews[above.indices[0]].spacing.distance(to: subviews[below.indices[0]].spacing, along: .vertical)
        }
    }
}

/// Check for Updates, with when the Persona's store installs were last checked in this run or why the check failed.
private struct UpdateCheckRow: View {
    @ObservedObject var webStore: WebStoreInstaller
    let plugins: PluginManager

    var body: some View {
        let check = webStore.updateChecks[plugins.persona]
        LabeledContent {
            Button("Check for Updates") {
                // The installer records a failure, which the row shows.
                Task { try? await webStore.checkForUpdates(in: plugins, onlyOncePerRun: false) }
            }
            .disabled(check == .checking)
        } label: {
            Text("Check the Web Store for newer versions of the extensions installed from it")
            switch check {
            case .checking:
                Text("Checking for updates\u{2026}")
            case let .checked(date):
                Text(Self.lastChecked(date))
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.red)
            case nil:
                EmptyView()
            }
        }
    }

    /// "Last checked at 10:42.", with the date for a check on another day, as a run can span days.
    private static func lastChecked(_ date: Date) -> String {
        guard Calendar.current.isDateInToday(date) else { return "Last checked on \(date.formatted(date: .abbreviated, time: .shortened))." }
        return "Last checked at \(date.formatted(date: .omitted, time: .shortened))."
    }
}

/// "Version 8.12.0 is available from the Web Store" with Review Update…, while the last update check found a newer version of the plugin installed from the store.
private struct UpdateRow: View {
    @ObservedObject var webStore: WebStoreInstaller
    let plugins: PluginManager
    let plugin: InstalledPlugin
    let review: () -> Void

    var body: some View {
        if let release = webStore.update(of: plugin, in: plugins) {
            LabeledContent("Version \(release.version) is available from the Web Store") {
                Button("Review Update\u{2026}", action: review)
            }
        }
    }
}

/// What the plugin's grant lets it do: a sentence for each permission and each site, or, with more than `InstalledPlugin.listedSiteLimit` sites, one sentence for the sites that names the broadest (`InstalledPlugin.accessBrief`), with every site's sentence behind a disclosure, as secondary text as the footers have it, so that a long list of sites does not push the section's other rows down while each permission stays in view.
private struct AccessRow: View {
    let plugin: InstalledPlugin

    var body: some View {
        if let brief = plugin.accessBrief {
            DisclosureGroup {
                Text(plugin.grant.sites.map(\.accessSummary).joined(separator: "\n"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                LabeledContent("Access") {
                    Text(brief.joined(separator: "\n"))
                        .multilineTextAlignment(.trailing)
                }
            }
        } else {
            LabeledContent("Access") {
                let summaries = plugin.accessSummaries
                Text(summaries.isEmpty ? "None" : summaries.joined(separator: "\n"))
                    .multilineTextAlignment(.trailing)
            }
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

/// The native apps that accept the plugin's versions, what Arch does not meet of their conditions, the vendors' steps, and what the app last did on WebKit tabs, as `NativeAppGuide` words them. The first showing in a run has Arch look for native apps, for the plugin on or off.
private struct NativeAppNotes: View {
    @ObservedObject var links: NativeMessagingHostLinks
    @ObservedObject var outcomes: NativeAppOutcomes
    let versions: [InstalledPlugin]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(NativeAppGuide.lines(for: versions, links: links, installation: .current, outcomes: outcomes).enumerated()), id: \.offset) { line in
                Text(line.element)
            }
        }
        .foregroundStyle(.secondary)
        .task { await NativeAppGuide.look(for: versions, in: links) }
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
            Text("\(version.pairEngine?.displayName ?? "") version")
            Text(["Version \(version.manifest.version), \(origin(of: version)).", plugins.enginesNote(of: version.id)].compactMap { $0 }.joined(separator: " "))
        }
        AccessRow(plugin: version)
        // Each failure is a red row of its own. A container would take a row in the form even without a failure.
        FailureNotes(plugin: version)
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
        // The form runs edge to edge, so its sections line up with the header and the buttons, as in the AI and Site Search editors.
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Join \u{201C}\(plugin.manifest.name)\u{201D} With Another Plugin")
                    .font(.headline)
                Text("Arch shows the two as one plugin with a version for each engine, and each engine runs only its version. Each version keeps its own access and storage.")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
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
                    .padding(.horizontal, 20)
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
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .onChange(of: other) { versions = plugins.proposedJoin(of: plugin.id, with: $1)?.versions ?? [:] }
    }

    /// The plugin's name with its version and where it came from, so that two plugins of one name differ.
    private func title(of plugin: InstalledPlugin) -> String {
        switch plugin.origin {
        case let .file(url): return "\(plugin.manifest.name) \(plugin.manifest.version) (\(url.lastPathComponent))"
        case .webStore: return "\(plugin.manifest.name) \(plugin.manifest.version) (Web Store)"
        case .bundled, .generated: return plugin.manifest.name
        }
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
    case .webStore:
        return "installed from the Web Store\(installDate)"
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
                SecureField("Secret", text: $draft, prompt: Text(isSaved ? "Saved" : "Not set"))
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
        Task {
            do {
                try await plugins.setSecret(secret, of: setting, for: plugin)
            } catch {
                onFailure(error)
            }
        }
    }
}

extension PluginKind {
    /// What Settings and the install sheet say about plugins of the kind, if anything, before where the plugin runs.
    var note: String? {
        self == .webExtension ? "A web extension." : nil
    }
}

extension InstalledPlugin {
    /// Which models a plugin with `ai` uses, for its section: those Settings ▸ AI ▸ Features gives its feature, which it needs of its own when its events run as hooks.
    var aiNote: String? {
        guard grant.permissions.contains(.ai) else { return nil }
        return runsHooks ? "Its events reach it, and its AI requests go out, once Settings \u{25B8} AI \u{25B8} Features gives it a model of its own."
                         : "Its AI requests use the model that Settings \u{25B8} AI \u{25B8} Features gives it, or the default model."
    }
}

private extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
