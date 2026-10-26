// The plugins of one Persona. The manager registers the built-in plugins and the plugins the user installed, script plugins and those of the kinds whose runtimes the app supplies, keeps which of them the user switched on or off and what it installed in `plugins.json`, exposes the contributions of the enabled ones, starts a plugin's code only when one of its commands runs, one of its panels opens, or one of its page scripts sends it a value, and keeps each plugin's data in the Persona's folder and its secrets in the Keychain. It stages plugins from the files the user chooses and script plugins from the files AI writes, installs, updates, and removes installed plugins, records which engines run the packages of kinds that engines check, keeps two web extension plugins that are versions of one extension as a pair with one engine each, tells each runtime which of its plugins are enabled, and switches off a script plugin whose background script fails three times within five minutes.
import AppKit
import ARCHEngine
import Combine
import UniformTypeIdentifiers

/// A plugin the manager knows, with its grant and whether it is enabled.
public struct InstalledPlugin: Identifiable, Hashable, Sendable {
    /// The install entry's identifier, which names the plugin's folder, choice, storage, and Keychain items: the manifest's, or, for a version that joined a plugin whose version has the same identifier, that followed by `.webkit` or `.chromium`. A built-in plugin's is its manifest's.
    public var id: PluginID { entryID ?? manifest.id }
    public var kind: PluginKind = .builtIn
    public var manifest: PluginManifest
    public var origin: PluginOrigin = .bundled
    /// The folder of the installed package; nil for a built-in plugin.
    public var packageURL: URL?
    public var grant: PluginGrant
    public var isEnabled: Bool
    /// When the user installed the plugin; nil for a built-in plugin.
    public var installedAt: Date?
    /// Why the manager switched the plugin off after repeated failures in this run, which Settings shows until the plugin is switched on again.
    public var failure: String?
    /// Why the plugin's runtime cannot run it on this Mac, which Settings shows; its contributions stay out meanwhile.
    public var unavailability: String?
    /// The current answers: whether each engine that runs the kind for the Persona and checked the package at the engine's present version runs it. Empty for kinds that Arch runs alike on every engine, and for engines that have not checked the package.
    public var engineChecks: [EngineKind: Bool] = [:]
    /// Why the package failed to start in this run on engines whose check it passed, each as a sentence that names the engine, which Settings shows until the plugin is switched on again or updates.
    public var engineFailures: [EngineKind: String] = [:]
    /// The install entry's identifier where it is not the manifest's.
    var entryID: PluginID?
    /// The other version of the plugin, in a pair.
    public var counterpart: PluginID?
    /// The engine that the pair's record gives the plugin, in a pair.
    public var pairEngine: EngineKind?
    /// The engines whose note asking for a version of the plugin the user dismissed.
    public var dismissedVersionNotes: Set<EngineKind> = []

    /// The engines a web extension runs on: those whose current answer runs its package, less those where it failed to start, and in a pair only the engine that the pair's record gives it. Empty for other kinds.
    public var engines: Set<EngineKind> {
        let running = Set(engineChecks.filter(\.value).keys).subtracting(engineFailures.keys)
        guard let pairEngine else { return running }
        return running.intersection([pairEngine])
    }

    /// The engines whose current answer runs the package, in a pair or not.
    var enginesRunningPackage: Set<EngineKind> {
        Set(engineChecks.filter(\.value).keys)
    }

    /// Where the plugin runs, as Settings says it, such as "Runs on WebKit tabs.", once an engine has checked its package; for a version of a pair whose engine refuses its package, such as "Chromium does not run this version."; or "No engine on this Mac runs it." when every engine that checked it refuses it. Nil while it starts on none of the engines that run it, whose failures say why.
    public var enginesNote: String? {
        guard !engineChecks.isEmpty else { return nil }
        if let note = PluginPackage.runsNote(on: engines) { return note }
        if let pairEngine, engineChecks[pairEngine] == false { return "\(pairEngine.displayName) does not run this version." }
        return engineChecks.values.contains(true) ? nil : "No engine on this Mac runs it."
    }

    /// The engines, in the order of `EngineKind`, for which Settings offers Install <Engine> Version…: each of the engines that a pair divides (`PluginEngineVersions.engines`) that is among `running`, the engines that run the kind on this Mac, while the plugin runs on another engine, whatever the checks found, since an engine may run a package built for the other engine. None in a pair.
    public func versionEngines(among running: Set<EngineKind>) -> [EngineKind] {
        guard counterpart == nil else { return [] }
        return PluginEngineVersions.engines.filter { engine in running.contains(engine) && engines.contains { $0 != engine } }
    }

    /// The engine whose version the plugin asks for, by the rule in Engine versions ▸ Guidance: one of `running` that has a current answer for the package and on which the plugin does not run, a failure to start counting, while it runs on another, and whose note the user has not dismissed. Nil in a pair.
    public func missingEngine(among running: Set<EngineKind>) -> EngineKind? {
        versionEngines(among: running).first { engineChecks[$0] != nil && !engines.contains($0) && !dismissedVersionNotes.contains($0) }
    }

    /// What the plugin may do, one sentence each, as Settings states it: its grant, then the API permissions that come with a web extension.
    public var accessSummaries: [String] {
        grant.summaries + [manifest.extensionPermissionsSummary].compactMap { $0 }
    }
}

@MainActor
public final class PluginManager: ObservableObject {
    /// A script plugin whose background script fails this often within `failureWindow` is switched off.
    private static let failureLimit = 3
    private static let failureWindow: TimeInterval = 5 * 60

    private let persona: PersonaID
    /// `Plugins/<persona id>/` in the app's Application Support folder, with `plugins.json`, a folder for each plugin named by its identifier, and `Staging/` for packages under review.
    private let directory: URL
    /// The built-in plugins in the order the app listed them, then the installed plugins in the order the user installed them, where the remaining version of a pair takes the place of the pair. Each version of a pair has its counterpart and its engine.
    @Published public private(set) var plugins: [InstalledPlugin] {
        didSet {
            contributions = PluginContributionIndex(plugins)
            runEnabledPlugins()
        }
    }
    @Published public private(set) var contributions: PluginContributionIndex
    /// The pairs whose versions are both listed, in the order the user made them.
    @Published public private(set) var engineVersions: [PluginEngineVersions] = []
    /// The badges the plugins set, by plugin and sidebar item.
    @Published private var badges: [PluginID: [String: String]] = [:]
    private let builtIns: [PluginID: any BuiltInPlugin.Type]
    /// The runtimes of the installed kinds that the manager does not run itself, which read their packages and run their plugins, by kind.
    private let runtimes: [PluginKind: any PluginRuntime]
    /// The packages of the installed plugins.
    private var packages: [PluginID: PluginPackage]
    /// The choices `plugins.json` keeps, in the order the user made them, including those for plugins this build does not have.
    private var choices: [PluginListFile.Choice]
    /// The installs `plugins.json` keeps, in the order the user installed the plugins, including those this build or its packages cannot read.
    private var installs: [PluginListFile.InstallEntry]
    /// The pairs `plugins.json` keeps, as it holds them, including those whose versions are not both listed or that name an engine this build does not know, which stay in the file and are ignored.
    private var pairRecords: [[String: String]]
    private let secretStore: any PluginSecretStore
    private let scriptLimits: ScriptPluginLimits
    /// Plugins whose code has started. Each starts at its first command, panel, or page script value and runs until it stops: when the user switches it off, updates it, removes it, or deletes the Persona, or the app quits, and a script plugin also when it stops on its own.
    private var running: [PluginID: RunningPlugin] = [:]
    /// The storage of each plugin, made when the plugin starts or its settings are first read. It outlives a failed activation, so the plugin's next start finds the changes that have not reached the file.
    private var storages: [PluginID: PluginStorageFile] = [:]
    /// When each script plugin's background script failed in the last `failureWindow`.
    private var failures: [PluginID: [Date]] = [:]

    /// A started plugin, its context, and its activation, which its commands, panels, and page script values wait for.
    private struct RunningPlugin {
        let plugin: any Plugin
        let context: ScopedPluginContext
        let activation: Task<Void, any Error>
        /// Whether the activation succeeded, after which uses reach the plugin without waiting.
        var isActive = false
    }

    /// `directory` is the app's Application Support folder. Built-in plugins get everything their manifests ask for. Of two built-in plugins with the same identifier, the first counts. The installed plugins follow, each read from its package, script plugins by the manager and other kinds by their `runtimes`; one whose package or `plugins.json` entry does not read, as one of a kind without a runtime, stays in the file but out of the list. A version whose identifier ends in an engine and that no record pairs, as a build before engine versions leaves it, is paired again with the other plugin of its package's identifier. The runtimes learn the enabled plugins of their kinds at once.
    public convenience init(persona: PersonaID, directory: URL, builtIns: [any BuiltInPlugin.Type], runtimes: [any PluginRuntime] = []) {
        self.init(persona: persona, directory: directory, builtIns: builtIns, runtimes: runtimes, secretStore: PluginKeychain())
    }

    init(persona: PersonaID, directory: URL, builtIns: [any BuiltInPlugin.Type], runtimes: [any PluginRuntime] = [], secretStore: any PluginSecretStore,
         scriptLimits: ScriptPluginLimits = .standard) {
        self.persona = persona
        self.directory = Self.folder(ofPersona: persona, in: directory)
        self.runtimes = Dictionary(runtimes.map { ($0.kind, $0) }) { first, _ in first }
        self.secretStore = secretStore
        self.scriptLimits = scriptLimits
        let list = PluginFile.read(PluginListFile.self, at: self.directory.appendingPathComponent(PluginListFile.name))
        let choices = list?.choices ?? []
        let installs = list?.installed ?? []
        var pairRecords = list?.engineVersions ?? []
        var plugins: [InstalledPlugin] = []
        var types: [PluginID: any BuiltInPlugin.Type] = [:]
        for type in builtIns where types[type.manifest.id] == nil {
            types[type.manifest.id] = type
            let choice = choices.first { $0.id == type.manifest.id.rawValue }
            plugins.append(InstalledPlugin(manifest: type.manifest, grant: PluginGrant(requestedBy: type.manifest), isEnabled: choice?.isEnabled ?? type.isOnByDefault))
        }
        var packages: [PluginID: PluginPackage] = [:]
        for case let .readable(install) in installs {
            guard let id = PluginID(rawValue: install.id), types[id] == nil, packages[id] == nil,
                  let package = try? PluginPackage(at: Self.packageFolder(of: id, in: self.directory), origin: install.origin, runtimes: runtimes),
                  Self.isEntry(id, of: package.manifest.id) else { continue }
            packages[id] = package
            plugins.append(Self.installedPlugin(package, id: id, install: install, isEnabled: choices.first { $0.id == install.id }?.isEnabled ?? false,
                                                runtime: self.runtimes[package.kind]))
        }
        let restored = Self.restoredRecords(for: plugins, records: pairRecords)
        pairRecords += restored
        let (paired, pairs) = Self.paired(plugins, records: pairRecords)
        self.plugins = paired
        engineVersions = pairs
        self.builtIns = types
        self.packages = packages
        self.choices = choices
        self.installs = installs
        self.pairRecords = pairRecords
        contributions = PluginContributionIndex(paired)
        // Packages that were under review when the app last quit cannot be installed any more.
        try? FileManager.default.removeItem(at: stagingDirectory)
        if !restored.isEmpty { saveList() }
        for runtime in self.runtimes.values {
            runtime.onFailure = { [weak self] id, reason in self?.setEnabled(false, for: [id], failure: reason) }
            runtime.onCheck = { [weak self] id, checks in self?.record(checks, for: id) }
            runtime.onEngineFailure = { [weak self] id, engine, reason in self?.recordEngineFailure(reason, of: id, on: engine) }
            runtime.onEnginesChange = { [weak self, kind = runtime.kind] in self?.readEngineChecks(of: kind) }
        }
        runEnabledPlugins()
    }

    /// The installed package as the list shows it under its entry's identifier, with the part of the entry's grant that its manifest asks for, with why its runtime cannot run it, if it cannot, with the current answers of the engines that checked it, and with the engines whose note asking for a version the user dismissed.
    private static func installedPlugin(_ package: PluginPackage, id: PluginID, install: PluginListFile.Install, isEnabled: Bool, runtime: (any PluginRuntime)?) -> InstalledPlugin {
        InstalledPlugin(kind: package.kind, manifest: package.manifest, origin: package.origin, packageURL: package.rootURL, grant: install.grant.limited(to: package.manifest),
                        isEnabled: isEnabled, installedAt: install.installedAt, unavailability: runtime?.unavailability,
                        engineChecks: currentChecks(install.engineChecks, engines: runtime?.engines ?? [:]), entryID: id == package.manifest.id ? nil : id,
                        dismissedVersionNotes: Set((install.dismissedVersionNotes ?? []).compactMap(EngineKind.init(rawValue:))))
    }

    /// Whether an install entry's identifier fits its package's: the same, or that followed by an engine's name, as a version that joined a plugin with the same identifier has it.
    private static func isEntry(_ id: PluginID, of manifestID: PluginID) -> Bool {
        id == manifestID || PluginEngineVersions.engines.contains { manifestID.version(for: $0) == id }
    }

    /// The plugins with the counterpart and the engine of each version of a pair, and the pairs: from the records, in their order, that give each engine one of two listed web extension plugins that no earlier record pairs.
    private static func paired(_ plugins: [InstalledPlugin], records: [[String: String]]) -> ([InstalledPlugin], [PluginEngineVersions]) {
        var plugins = plugins
        for index in plugins.indices {
            plugins[index].counterpart = nil
            plugins[index].pairEngine = nil
        }
        var pairs: [PluginEngineVersions] = []
        for record in records {
            guard let pair = PluginEngineVersions(fileRecord: record), pair.isComplete else { continue }
            let indices = pair.plugins.compactMap { id in plugins.firstIndex { $0.id == id } }
            guard indices.count == 2, indices.allSatisfy({ plugins[$0].kind == .webExtension && plugins[$0].packageURL != nil && plugins[$0].counterpart == nil }) else { continue }
            for (engine, id) in pair.versions {
                guard let index = plugins.firstIndex(where: { $0.id == id }) else { continue }
                plugins[index].pairEngine = engine
                plugins[index].counterpart = pair.versions.values.first { $0 != id }
            }
            pairs.append(pair)
        }
        return (plugins, pairs)
    }

    /// Records that pair again each version whose identifier ends in an engine and that no record pairs, as a build before engine versions leaves it, with the only other unpaired plugin of its package's identifier: the version for the engine its identifier names, the other plugin for the pair's other engine.
    private static func restoredRecords(for plugins: [InstalledPlugin], records: [[String: String]]) -> [[String: String]] {
        let listed = paired(plugins, records: records).0
        var restored: [[String: String]] = []
        var taken: Set<PluginID> = []
        for version in listed where version.kind == .webExtension && version.entryID != nil && version.counterpart == nil && !taken.contains(version.id) {
            guard let engine = PluginEngineVersions.engines.first(where: { version.manifest.id.version(for: $0) == version.id }),
                  let otherEngine = PluginEngineVersions.other(than: engine) else { continue }
            let others = listed.filter { $0.id != version.id && $0.kind == version.kind && $0.manifest.id == version.manifest.id && $0.counterpart == nil && !taken.contains($0.id) }
            guard others.count == 1, let other = others.first, other.entryID == nil || other.id == version.manifest.id.version(for: otherEngine) else { continue }
            restored.append(PluginEngineVersions([engine: version.id, otherEngine: other.id]).fileRecord)
            taken.formUnion([version.id, other.id])
        }
        return restored
    }

    /// Sets the list with the counterpart and the engine of each version of a pair, from the records the file keeps.
    private func setPlugins(_ next: [InstalledPlugin]) {
        let (paired, pairs) = Self.paired(next, records: pairRecords)
        if pairs != engineVersions { engineVersions = pairs }
        plugins = paired
    }

    /// The answers in an install entry that engines of `engines` gave at their present versions. An engine name this build does not know, and an answer from another version of the engine, count as no check.
    private static func currentChecks(_ checks: [String: PluginListFile.EngineCheck]?, engines: [EngineKind: String]) -> [EngineKind: Bool] {
        var current: [EngineKind: Bool] = [:]
        for (name, check) in checks ?? [:] {
            guard let engine = EngineKind(rawValue: name), engines[engine] == check.version else { continue }
            current[engine] = check.runs
        }
        return current
    }

    /// The answers as an install entry keeps them, each with the version of the engine of `engines` that gave it.
    private static func fileChecks(_ checks: [EngineKind: PluginEngineCheck], engines: [EngineKind: String]) -> [String: PluginListFile.EngineCheck] {
        var file: [String: PluginListFile.EngineCheck] = [:]
        for (engine, check) in checks {
            guard let version = engines[engine] else { continue }
            file[engine.rawValue] = PluginListFile.EngineCheck(runs: check == .runs, version: version)
        }
        return file
    }

    /// The first engine's refusal, in the order of `EngineKind`, when every engine that checked a package refused it; nil when one runs it or none checked it.
    private static func refusal(in checks: [EngineKind: PluginEngineCheck]) -> String? {
        guard !checks.values.contains(.runs) else { return nil }
        return EngineKind.allCases.lazy.compactMap { engine -> String? in
            guard case let .refused(reason)? = checks[engine] else { return nil }
            return reason
        }.first
    }

    /// Tells each runtime the installed plugins of its kind, on or off, so that it runs the enabled ones; none while it cannot run them on this Mac.
    private func runEnabledPlugins() {
        for (kind, runtime) in runtimes {
            runtime.run(plugins.filter { $0.kind == kind && $0.unavailability == nil })
        }
    }

    // MARK: Switching plugins on and off

    /// Records the choice in `plugins.json`. Switching a plugin off removes its contributions, so its page scripts stop at each tab's next load and their values no longer reach it, drops its badges, and stops its code. Either version of a pair switches both.
    public func setEnabled(_ isEnabled: Bool, for id: PluginID) {
        setEnabled(isEnabled, for: [id] + [plugins.first { $0.id == id }?.counterpart].compactMap { $0 }, failure: nil)
    }

    /// `failure` says why the manager switches the plugins off, for Settings. The manager switches off one version of a pair alone, so that its counterpart keeps running.
    private func setEnabled(_ isEnabled: Bool, for ids: [PluginID], failure: String?) {
        var next = plugins
        var changed: [PluginID] = []
        for id in ids {
            guard let index = next.firstIndex(where: { $0.id == id }), next[index].isEnabled != isEnabled else { continue }
            recordChoice(isEnabled, for: id)
            next[index].isEnabled = isEnabled
            next[index].failure = failure
            // Switching a plugin on tries again the engines where it failed to start; the runtime checks again the package of one that every engine refused.
            if isEnabled { next[index].engineFailures = [:] }
            changed.append(id)
        }
        guard !changed.isEmpty else { return }
        saveList()
        plugins = next
        for id in changed {
            failures[id] = nil
            if !isEnabled {
                badges[id] = nil
                stop(id)
            }
        }
    }

    /// A new choice for a plugin replaces its old one.
    private func recordChoice(_ isEnabled: Bool, for id: PluginID) {
        choices.removeAll { $0.id == id.rawValue }
        choices.append(PluginListFile.Choice(id: id.rawValue, isEnabled: isEnabled))
    }

    /// Choices, installs, pairs, and dismissals are few and rare, so each writes the file at once.
    private func saveList() {
        guard let data = try? JSONEncoder().encode(PluginListFile(choices: choices, installed: installs, engineVersions: pairRecords.isEmpty ? nil : pairRecords)) else { return }
        PluginFile.write(data, to: directory.appendingPathComponent(PluginListFile.name))
    }

    /// Drops the plugin's running instance, whose context stops acting at once and which deactivates once its activation ends.
    private func stop(_ id: PluginID) {
        guard let stopped = running.removeValue(forKey: id) else { return }
        stopped.context.end()
        Task {
            guard (try? await stopped.activation.value) != nil else { return }
            await stopped.plugin.deactivate()
        }
    }

    // MARK: Installing script plugins

    /// `Staging/` in the Persona's folder, where packages wait for review.
    private var stagingDirectory: URL {
        directory.appendingPathComponent("Staging", isDirectory: true)
    }

    /// Copies a folder, `.zip` archive, or `.crx` file the user chose into the staging folder and reads its package there for the install sheet, without running any of it: a script plugin's, or one of a kind that a runtime reads. The engines that run the kind on this Mac check the package, and the installed plugins it could update or join as a version, in the engines that have no current answer for them; the package then names what the review offers (see `PluginPackage`). Throws `PluginError.invalidPackage` or `.unsupportedAPIVersion` for a package Arch cannot install, for one whose identifier `checkInstallable(_:of:)` refuses, and, with the first engine's reason, for one that every engine refuses. A staged package ends with `install(_:grant:isEnabled:asVersionOf:for:)` or `discard(_:)`.
    public func stage(_ url: URL) async throws -> PluginPackage {
        let runtimes = Array(runtimes.values)
        return try await stage { root in try PluginPackage.stage(url, at: root, runtimes: runtimes) }
    }

    /// Writes the files of a plugin that AI wrote, `plugin.json` among them, at their package paths in the staging folder and reads its package there, as `stage(_:)` does for a folder.
    public func stage(_ files: [String: String], writtenBy composition: PluginComposition) async throws -> PluginPackage {
        try await stage { root in try PluginPackage.stage(files, at: root, origin: .generated(composition)) }
    }

    /// The package that `make` puts in a new folder of the staging folder, off the main thread, kept only while `checkInstallable(_:of:)` accepts its identifier and, for a kind that engines check, while an engine runs it.
    private func stage(_ make: @escaping @Sendable (URL) throws -> PluginPackage) async throws -> PluginPackage {
        let root = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var package = try await Task.detached { try make(root) }.value
        do {
            try checkInstallable(package.manifest.id, of: package.kind)
            if let runtime = self.runtimes[package.kind], !runtime.engines.isEmpty {
                await checkUnanswered(installedVersions(withIdentifier: package.manifest.id, kind: package.kind) + [counterpartCandidate(for: package)].compactMap { $0 }, in: runtime)
                package.engineChecks = await runtime.check(packageAt: package.rootURL)
                if let refusal = Self.refusal(in: package.engineChecks) { throw PluginError.invalidPackage(refusal) }
                offerVersions(for: &package, running: Set(runtime.engines.keys))
            } else {
                package.updates = installedVersions(withIdentifier: package.manifest.id, kind: package.kind).first?.id
            }
        } catch {
            discard(package)
            throw error
        }
        return package
    }

    /// Checks the installed plugins, on or off, in the runtime's engines that have no current answer for them, and records the answers.
    private func checkUnanswered(_ installed: [InstalledPlugin], in runtime: any PluginRuntime) async {
        var checked: Set<PluginID> = []
        for plugin in installed where checked.insert(plugin.id).inserted {
            guard let packageURL = plugin.packageURL else { continue }
            let unanswered = Set(runtime.engines.keys).subtracting(plugins.first { $0.id == plugin.id }?.engineChecks.keys ?? plugin.engineChecks.keys)
            guard !unanswered.isEmpty else { continue }
            record(await runtime.check(packageAt: packageURL).filter { unanswered.contains($0.key) }, for: plugin.id)
        }
    }

    /// The installed plugins of the kind whose packages have the identifier: one, or the two versions of a pair that share it, in the order the user installed them.
    private func installedVersions(withIdentifier id: PluginID, kind: PluginKind) -> [InstalledPlugin] {
        plugins.filter { $0.packageURL != nil && $0.kind == kind && $0.manifest.id == id }
    }

    /// The installed plugin that the package matches as a version of the same extension, by the rule in Engine versions ▸ Counterparts: the one with the package's identifier while it is the only one and not in a pair, or, while no plugin has the identifier, the first installed that is not in a pair and whose manifest names the same extension.
    private func counterpartCandidate(for package: PluginPackage) -> InstalledPlugin? {
        let versions = installedVersions(withIdentifier: package.manifest.id, kind: package.kind)
        guard versions.isEmpty else { return versions.count == 1 && versions[0].counterpart == nil ? versions[0] : nil }
        return plugins.first { $0.kind == package.kind && $0.packageURL != nil && $0.counterpart == nil && $0.manifest.namesSameExtension(as: package.manifest) }
    }

    /// Sets what the review offers for the checked package, by the answers at staging: the plugin it updates and, where the rule leaves two, the versions to choose between; the plugin it matches; each engine of `running` that runs the package while the match runs on the pair's other engine; and the engine the choice starts on when the two complement each other.
    private func offerVersions(for package: inout PluginPackage, running: Set<EngineKind>) {
        (package.updates, package.updateChoices) = Self.updateTarget(of: package, among: installedVersions(withIdentifier: package.manifest.id, kind: package.kind))
        guard let match = counterpartCandidate(for: package) else { return }
        package.counterpart = match.id
        package.joinableEngines = PluginEngineVersions.engines.filter { engine in
            running.contains(engine) && package.engineChecks[engine] == .runs && PluginEngineVersions.other(than: engine).map(match.engines.contains) == true
        }
        package.suggestedEngine = package.joinableEngines.first { engine in
            guard match.engineChecks[engine] == false, let other = PluginEngineVersions.other(than: engine), case .refused? = package.engineChecks[other] else { return false }
            return match.engines.contains(other)
        }
    }

    /// The installed plugin that a package with an installed identifier updates: the only one with it; of two versions with it, the one installed from the same source, else the one whose answers the package's checks equal, else the first, with both for the review to choose between.
    private static func updateTarget(of package: PluginPackage, among versions: [InstalledPlugin]) -> (PluginID?, [PluginID]) {
        guard versions.count > 1 else { return (versions.first?.id, []) }
        if case let .file(packageSource) = package.origin,
           let same = versions.first(where: { if case let .file(url) = $0.origin { return url.standardizedFileURL.path == packageSource.standardizedFileURL.path } else { return false } }) {
            return (same.id, [])
        }
        let answers = package.engineChecks.mapValues { $0 == .runs }
        let equal = versions.filter { $0.engineChecks == answers }
        if equal.count == 1 { return (equal[0].id, []) }
        return (versions[0].id, versions.map(\.id))
    }

    /// Throws `PluginError.invalidPackage` for an identifier that no installed plugin of `kind` may have: a built-in plugin's, one of earlier builds that `PluginIdentifierMigration` renames at launch, an installed plugin's of another kind, which an update cannot turn into this kind, the install entry's identifier of a version that joined under its counterpart's identifier, such as `extension.<identifier>.chromium`, which an install would otherwise replace although its package names another identifier, or the name of `plugins.json` or of the copy kept of it when it does not decode, which the plugin's folder would take in the Persona's folder.
    private func checkInstallable(_ id: PluginID, of kind: PluginKind) throws {
        guard builtIns[id] == nil else { throw PluginError.invalidPackage("A plugin built into Arch has the identifier \(id.rawValue).") }
        if let renamed = PluginIdentifierMigration.renamed(id.rawValue) {
            throw PluginError.invalidPackage("Arch renames the identifier \(id.rawValue) to \(renamed) at launch, so no plugin can have it as its identifier.")
        }
        if packages.values.contains(where: { $0.manifest.id == id && $0.kind != kind }) {
            throw PluginError.invalidPackage("An installed plugin of another kind has the identifier \(id.rawValue).")
        }
        if packages.contains(where: { $0.key == id && $0.value.manifest.id != id }) {
            throw PluginError.invalidPackage("A version of an installed plugin has the identifier \(id.rawValue).")
        }
        let list = directory.appendingPathComponent(PluginListFile.name)
        guard ![list, PluginFile.unreadableURL(of: list)].contains(where: { $0.lastPathComponent == id.rawValue }) else {
            throw PluginError.invalidPackage("Arch keeps a file named \(id.rawValue) beside the installed plugins, so no plugin can have it as its identifier.")
        }
    }

    /// Deletes a staged package that the user chose not to install.
    public func discard(_ package: PluginPackage) {
        guard package.rootURL.deletingLastPathComponent().standardizedFileURL == stagingDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: package.rootURL)
    }

    /// Installs a staged package in the Persona with the part of `grant` that its manifest asks for, enabled or not as `isEnabled` says, and returns the plugin's identifier. With `asVersionOf` and `engine`, the package joins that plugin as its version for the engine, on or off as the plugin is. Otherwise a package with an installed plugin's identifier updates `package.updates`, or the first plugin with the identifier: the new package replaces the old one, the plugin keeps its place, storage, secrets, pair, and dismissed notes, and its running instance stops, so that its next use starts the new code. A new plugin that could have joined its counterpart as a version has, as has the counterpart, the note asking for a version dismissed for the engines the other runs on. Throws `PluginError.invalidPackage` for a version that cannot join (see `versionJoin(_:joining:for:)`) and for an update that would leave a version of a pair on no engine (`updateRefusal(for:updating:)`).
    @discardableResult
    public func install(_ package: PluginPackage, grant: PluginGrant, isEnabled: Bool, asVersionOf version: PluginID? = nil, for engine: EngineKind? = nil) throws -> PluginID {
        try checkInstallable(package.manifest.id, of: package.kind)
        let id: PluginID
        var isEnabled = isEnabled
        var pair: PluginEngineVersions?
        if let version, let engine {
            let join = try versionJoin(package, joining: version, for: engine)
            (id, pair, isEnabled) = (join.id, join.pair, join.isEnabled)
        } else {
            id = package.updates ?? installedVersions(withIdentifier: package.manifest.id, kind: package.kind).first?.id ?? package.manifest.id
            if let refusal = updateRefusal(for: package, updating: id) { throw PluginError.invalidPackage(refusal) }
        }
        let isNew = !plugins.contains { $0.id == id }
        let destination = Self.packageFolder(of: id, in: directory)
        let fileManager = FileManager.default
        badges[id] = nil
        stop(id)
        let installedRoot: URL
        if fileManager.fileExists(atPath: destination.path) {
            installedRoot = try fileManager.replaceItemAt(destination, withItemAt: package.rootURL) ?? destination
        } else {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: package.rootURL, to: destination)
            installedRoot = destination
        }
        let installed = package.moved(to: installedRoot)
        packages[id] = installed
        let runtime = runtimes[installed.kind]
        let checks = Self.fileChecks(package.engineChecks, engines: runtime?.engines ?? [:])
        var install = PluginListFile.Install(id: id.rawValue, origin: package.origin, grant: grant.limited(to: package.manifest), installedAt: Date(),
                                             engineChecks: checks.isEmpty ? nil : checks)
        if let index = installs.firstIndex(where: { $0.id == install.id }) {
            if case let .readable(old) = installs[index] { install.dismissedVersionNotes = old.dismissedVersionNotes }
            installs[index] = .readable(install)
        } else {
            installs.append(.readable(install))
        }
        recordChoice(isEnabled, for: id)
        failures[id] = nil
        let plugin = Self.installedPlugin(installed, id: id, install: install, isEnabled: isEnabled, runtime: runtime)
        var next = plugins
        if let index = next.firstIndex(where: { $0.id == id }) {
            next[index] = plugin
        } else {
            next.append(plugin)
        }
        if let pair {
            dropRecords(naming: pair.plugins)
            pairRecords.append(pair.fileRecord)
        } else if isNew, !package.joinableEngines.isEmpty, let counterpart = package.counterpart, let match = next.first(where: { $0.id == counterpart }) {
            // The user chose to keep the two apart.
            dismiss(match.enginesRunningPackage, notesOf: id, in: &next)
            dismiss(plugin.enginesRunningPackage, notesOf: counterpart, in: &next)
        }
        saveList()
        setPlugins(next)
        return id
    }

    /// The entry identifier, the pair, and the switch of a package that joins the plugin `id` as its version for `engine`: the package's identifier, or, when the plugin's version has it too, that followed by the engine's name. The plugin keeps the pair's other engine, and the version takes its switch. Throws `PluginError.invalidPackage` for a plugin that is not an installed web extension outside a pair, a package that the engine has not checked or refused, a plugin whose current answer does not run it on the other engine, and a package with the identifier of another installed plugin.
    private func versionJoin(_ package: PluginPackage, joining id: PluginID, for engine: EngineKind) throws -> (id: PluginID, pair: PluginEngineVersions, isEnabled: Bool) {
        guard let plugin = plugins.first(where: { $0.id == id }), plugin.kind == .webExtension, plugin.kind == package.kind, plugin.packageURL != nil,
              let other = PluginEngineVersions.other(than: engine) else {
            throw PluginError.invalidPackage("Only an installed web extension can have a version for \(engine.displayName).")
        }
        guard plugin.counterpart == nil else { throw PluginError.invalidPackage("\u{201C}\(plugin.manifest.name)\u{201D} already has a version for each engine.") }
        switch package.engineChecks[engine] {
        case .runs?: break
        case let .refused(reason)?: throw PluginError.invalidPackage(reason)
        case nil: throw PluginError.invalidPackage("\(engine.displayName) has not checked this package.")
        }
        guard plugin.engineChecks[other] == true else {
            throw PluginError.invalidPackage("\(other.displayName) does not run \u{201C}\(plugin.manifest.name)\u{201D}, so it cannot keep \(other.displayName) tabs.")
        }
        let manifestID = package.manifest.id
        guard !plugins.contains(where: { $0.id != plugin.id && $0.manifest.id == manifestID }) else {
            throw PluginError.invalidPackage("Another installed plugin has this package's identifier, so it cannot join \u{201C}\(plugin.manifest.name)\u{201D} here. Join With\u{2026} joins installed plugins.")
        }
        let candidates = plugin.manifest.id == manifestID ? [manifestID.version(for: engine), manifestID] : [manifestID]
        guard let entryID = candidates.compactMap({ $0 }).first(where: { candidate in !plugins.contains { $0.id == candidate } }) else {
            throw PluginError.invalidPackage("An installed plugin has the identifier this version would take.")
        }
        return (entryID, PluginEngineVersions([engine: entryID, other: plugin.id]), plugin.isEnabled)
    }

    /// Why the package cannot join the plugin `id` as its version for `engine`, as the review states it, or nil when it can.
    public func versionRefusal(for package: PluginPackage, joining id: PluginID, for engine: EngineKind) -> String? {
        do {
            _ = try versionJoin(package, joining: id, for: engine)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The review's warning for a package that joins the plugin `id` as its version for `engine` under the plugin's own identifier, from another place than the plugin's, while the plugin's package runs on that engine: the engine knows both by that identifier, so the version takes over the extension storage that the plugin's copy keeps there, as an update from another place takes over the plugin's data. Nil otherwise.
    public func versionTakeover(for package: PluginPackage, joining id: PluginID, for engine: EngineKind) -> String? {
        guard let plugin = plugins.first(where: { $0.id == id }), plugin.manifest.id == package.manifest.id, plugin.enginesRunningPackage.contains(engine),
              case let .file(source) = plugin.origin, case let .file(packageSource) = package.origin,
              source.standardizedFileURL.path != packageSource.standardizedFileURL.path else { return nil }
        let name = "\u{201C}\(plugin.manifest.name)\u{201D}"
        return "\(name), which you installed from \(source.lastPathComponent), has this package's identifier, so as its \(engine.displayName) version the package takes over the data that \(name) keeps on \(engine.displayName) tabs. Join only if both come from the same developer."
    }

    /// Why the package cannot update the plugin `id`, or `package.updates`, while its pair lasts: its check refuses the engine that the pair's record gives that version, such as "WebKit cannot run this package, and the other version of “Reader” runs on Chromium tabs." Nil when it can.
    public func updateRefusal(for package: PluginPackage, updating id: PluginID? = nil) -> String? {
        guard let target = (id ?? package.updates).flatMap({ id in plugins.first { $0.id == id } }), let engine = target.pairEngine, case .refused? = package.engineChecks[engine],
              let counterpart = plugins.first(where: { $0.id == target.counterpart }), let otherEngine = counterpart.pairEngine, let name = leadVersion(of: target.id)?.manifest.name else { return nil }
        return "\(engine.displayName) cannot run this package, and the other version of \u{201C}\(name)\u{201D} runs on \(otherEngine.displayName) tabs."
    }

    // MARK: Engine versions

    /// The plugin, or, for a version of a pair, the version installed first, whose name and place in the list the pair takes.
    public func leadVersion(of id: PluginID) -> InstalledPlugin? {
        guard let plugin = plugins.first(where: { $0.id == id }) else { return nil }
        guard let counterpart = plugin.counterpart else { return plugin }
        return plugins.first { $0.id == id || $0.id == counterpart }
    }

    /// The engine whose version the plugin asks for, by the rule in Engine versions ▸ Guidance, or nil.
    public func missingEngine(of id: PluginID) -> EngineKind? {
        guard let plugin = plugins.first(where: { $0.id == id }), let runtime = runtimes[plugin.kind] else { return nil }
        return plugin.missingEngine(among: Set(runtime.engines.keys))
    }

    /// The engines for which the plugin's section in Settings offers Install <Engine> Version….
    public func versionEngines(of id: PluginID) -> [EngineKind] {
        guard let plugin = plugins.first(where: { $0.id == id }), let runtime = runtimes[plugin.kind] else { return [] }
        return plugin.versionEngines(among: Set(runtime.engines.keys))
    }

    /// Where the plugin runs, as Settings says it (`InstalledPlugin.enginesNote`), or, for a version of a pair whose engine runs no web extensions on this Mac now, as when its application did not start, such as "Chromium runs no web extensions on this Mac."
    public func enginesNote(of id: PluginID) -> String? {
        guard let plugin = plugins.first(where: { $0.id == id }) else { return nil }
        if let engine = plugin.pairEngine, let runtime = runtimes[plugin.kind], runtime.engines[engine] == nil {
            return "\(engine.displayName) runs no web extensions on this Mac."
        }
        return plugin.enginesNote
    }

    /// The other installed web extension plugins outside a pair that Join With… in the plugin's section lists, in the order the user installed them. None for a plugin in a pair, and none while an engine that a pair divides runs no web extensions on this Mac, as Chromium before VI.1, since its version would run nowhere.
    public func joinCandidates(of id: PluginID) -> [InstalledPlugin] {
        let unpaired = { (plugin: InstalledPlugin) in plugin.kind == .webExtension && plugin.packageURL != nil && plugin.counterpart == nil }
        guard let plugin = plugins.first(where: { $0.id == id }), unpaired(plugin), let runtime = runtimes[plugin.kind],
              PluginEngineVersions.engines.allSatisfy({ runtime.engines[$0] != nil }) else { return [] }
        return plugins.filter { $0.id != id && unpaired($0) }
    }

    /// The types the open panel of Install <Engine> Version… accepts for the plugin's version for the engine.
    public func packageTypes(forVersionOf id: PluginID, for engine: EngineKind) -> [UTType] {
        guard let plugin = plugins.first(where: { $0.id == id }), let runtime = runtimes[plugin.kind] else { return [] }
        return runtime.packageTypes(for: engine)
    }

    /// The pair that Join With… starts on for two plugins: each engine to the plugin whose current answer alone runs its package there, else to the one installed first unless it refuses the engine; and where that leaves a plugin without an engine, the other plugin takes the engine where its answer is best, of two alike the one that leaves the version installed first the earlier engine of `PluginEngineVersions.engines`.
    public func proposedJoin(of id: PluginID, with otherID: PluginID) -> PluginEngineVersions? {
        guard id != otherID, let firstIndex = plugins.firstIndex(where: { $0.id == id || $0.id == otherID }),
              let secondIndex = plugins.lastIndex(where: { $0.id == id || $0.id == otherID }), firstIndex != secondIndex else { return nil }
        let (first, second) = (plugins[firstIndex], plugins[secondIndex])
        var versions: [EngineKind: PluginID] = [:]
        for engine in PluginEngineVersions.engines {
            let secondAlone = second.engineChecks[engine] == true && first.engineChecks[engine] != true
            versions[engine] = secondAlone || (first.engineChecks[engine] == false && second.engineChecks[engine] != false) ? second.id : first.id
        }
        if let only = Set(versions.values).first, Set(versions.values).count == 1 {
            let taker = only == first.id ? second : first
            let kept = only == first.id ? first : second
            let score = { (engine: EngineKind) -> Int in
                switch taker.engineChecks[engine] {
                case true?: return kept.engineChecks[engine] == true ? 2 : 3
                case nil: return 1
                case false?: return 0
                }
            }
            // `max(by:)` keeps the first of the engines that score alike, so the version installed first, as `kept` or `taker`, keeps or takes the earlier engine.
            let order = taker.id == first.id ? PluginEngineVersions.engines : Array(PluginEngineVersions.engines.reversed())
            if let engine = order.max(by: { score($0) < score($1) }), score(engine) > 0 { versions[engine] = taker.id }
        }
        return PluginEngineVersions(versions)
    }

    /// Makes the two plugins of `versions` one plugin with a version per engine, at the place of the version installed first, whose switch the pair takes. The join drops each record of the file that names one of its plugins, those it ignores among them. Throws `PluginError.invalidVersions` for a record that does not give each engine one of two plugins, a plugin that is not an installed web extension or is in a pair, an engine that runs no web extensions on this Mac, and a version whose current answer does not run its package on the engine the record gives it, as one that refuses it or has not checked it, since such a version would run nowhere.
    public func join(_ versions: PluginEngineVersions) throws {
        guard versions.isComplete else { throw PluginError.invalidVersions("Each engine needs one of the two versions.") }
        let members = try versions.plugins.map { id -> InstalledPlugin in
            guard let plugin = plugins.first(where: { $0.id == id }), plugin.kind == .webExtension, plugin.packageURL != nil else {
                throw PluginError.invalidVersions("Only installed web extensions can be versions of one plugin.")
            }
            guard plugin.counterpart == nil else { throw PluginError.invalidVersions("\u{201C}\(plugin.manifest.name)\u{201D} is already one of two versions.") }
            return plugin
        }
        let running = runtimes[.webExtension]?.engines ?? [:]
        for engine in PluginEngineVersions.engines {
            guard let plugin = members.first(where: { $0.id == versions.versions[engine] }) else { continue }
            guard running[engine] != nil else { throw PluginError.invalidVersions("\(engine.displayName) runs no web extensions on this Mac, so no version can run on it.") }
            switch plugin.engineChecks[engine] {
            case true?:
                continue
            case false?:
                throw PluginError.invalidVersions("\(engine.displayName) does not run \u{201C}\(plugin.manifest.name)\u{201D}, so it cannot be the \(engine.displayName) version.")
            case nil:
                throw PluginError.invalidVersions("\(engine.displayName) has not checked \u{201C}\(plugin.manifest.name)\u{201D} yet, so it cannot be the \(engine.displayName) version.")
            }
        }
        guard let lead = plugins.first(where: { versions.plugins.contains($0.id) }) else { return }
        dropRecords(naming: versions.plugins)
        pairRecords.append(versions.fileRecord)
        var next = plugins
        var stopped: [PluginID] = []
        for member in members where member.id != lead.id && member.isEnabled != lead.isEnabled {
            guard let index = next.firstIndex(where: { $0.id == member.id }) else { continue }
            recordChoice(lead.isEnabled, for: member.id)
            next[index].isEnabled = lead.isEnabled
            next[index].failure = nil
            next[index].engineFailures = [:]
            if !lead.isEnabled { stopped.append(member.id) }
        }
        saveList()
        setPlugins(next)
        for id in stopped {
            badges[id] = nil
            stop(id)
        }
    }

    /// Makes the versions of the plugin's pair two plugins again, each on every engine its package runs on, with their switches as they were, and dismisses each one's note asking for a version for the engines the other runs on, since the user chose to keep them apart. Throws `PluginError.invalidVersions` for a pair whose versions share an engine identifier, since an engine loads one plugin per identifier.
    public func separate(_ id: PluginID) throws {
        guard let plugin = plugins.first(where: { $0.id == id }), let counterpart = plugins.first(where: { $0.id == plugin.counterpart }) else { return }
        guard plugin.manifest.id != counterpart.manifest.id else {
            throw PluginError.invalidVersions("Both versions of \u{201C}\(leadVersion(of: id)?.manifest.name ?? plugin.manifest.name)\u{201D} have one identifier, which each engine loads only once, so they stay one plugin. Remove a version instead.")
        }
        dropRecords(naming: [plugin.id, counterpart.id])
        var next = plugins
        dismiss(counterpart.enginesRunningPackage, notesOf: plugin.id, in: &next)
        dismiss(plugin.enginesRunningPackage, notesOf: counterpart.id, in: &next)
        saveList()
        setPlugins(next)
    }

    /// Records that the user dismissed the note asking for the plugin's version for the engine, in `plugins.json` at once.
    public func dismissVersionNote(of id: PluginID, for engine: EngineKind) {
        var next = plugins
        dismiss([engine], notesOf: id, in: &next)
        guard next != plugins else { return }
        saveList()
        plugins = next
    }

    /// Adds the engines to the plugin's dismissed notes, in `plugins` and in its install entry, which keeps the names this build does not know.
    private func dismiss(_ engines: Set<EngineKind>, notesOf id: PluginID, in plugins: inout [InstalledPlugin]) {
        guard let index = plugins.firstIndex(where: { $0.id == id }), let entry = installs.firstIndex(where: { $0.id == id.rawValue }),
              case var .readable(install) = installs[entry] else { return }
        for engine in EngineKind.allCases where engines.contains(engine) && !plugins[index].dismissedVersionNotes.contains(engine) {
            plugins[index].dismissedVersionNotes.insert(engine)
            install.dismissedVersionNotes = (install.dismissedVersionNotes ?? []) + [engine.rawValue]
        }
        installs[entry] = .readable(install)
    }

    /// Drops the records of the file that name one of the plugins, those it ignores among them, so that no plugin is in two records.
    private func dropRecords(naming ids: [PluginID]) {
        let names = Set(ids.map(\.rawValue))
        pairRecords.removeAll { !names.isDisjoint(with: $0.values) }
    }

    // MARK: Engines

    /// Records what engines found when they checked an installed plugin's package, each answer with the engine's version, in the plugin and its install entry, which keeps the answers of engines this build does not know. An enabled plugin that every engine of its kind's runtime now refuses is switched off with the first engine's reason.
    private func record(_ checks: [EngineKind: PluginEngineCheck], for id: PluginID) {
        guard let index = plugins.firstIndex(where: { $0.id == id }), let runtime = runtimes[plugins[index].kind],
              let entry = installs.firstIndex(where: { $0.id == id.rawValue }), case var .readable(install) = installs[entry] else { return }
        let answers = Self.fileChecks(checks, engines: runtime.engines)
        guard !answers.isEmpty else { return }
        install.engineChecks = (install.engineChecks ?? [:]).merging(answers) { $1 }
        installs[entry] = .readable(install)
        saveList()
        var plugin = plugins[index]
        plugin.engineChecks = Self.currentChecks(install.engineChecks, engines: runtime.engines)
        plugins[index] = plugin
        if plugin.isEnabled, runtime.engines.keys.allSatisfy({ plugin.engineChecks[$0] == false }), let reason = Self.refusal(in: checks) {
            setEnabled(false, for: [id], failure: reason)
        }
    }

    /// Reads the current answers of the kind's plugins from their install entries again, and why the kind cannot run, after its runtime's engines changed.
    private func readEngineChecks(of kind: PluginKind) {
        guard let runtime = runtimes[kind] else { return }
        var plugins = plugins
        for index in plugins.indices where plugins[index].kind == kind {
            guard case let .readable(install)? = installs.first(where: { $0.id == plugins[index].id.rawValue }) else { continue }
            plugins[index].engineChecks = Self.currentChecks(install.engineChecks, engines: runtime.engines)
            plugins[index].unavailability = runtime.unavailability
        }
        if plugins != self.plugins { self.plugins = plugins }
    }

    /// Keeps why the plugin failed to start on the engine for the run, so that the engine counts as one it does not run on, and switches the plugin off with every engine's reason once it has failed on each engine it ran on.
    private func recordEngineFailure(_ reason: String, of id: PluginID, on engine: EngineKind) {
        guard let index = plugins.firstIndex(where: { $0.id == id }), plugins[index].isEnabled else { return }
        var plugin = plugins[index]
        plugin.engineFailures[engine] = reason
        plugins[index] = plugin
        guard plugin.engines.isEmpty else { return }
        setEnabled(false, for: [id], failure: EngineKind.allCases.compactMap { plugin.engineFailures[$0] }.joined(separator: "\n"))
    }

    /// Deletes an installed plugin, or one version of a pair, from the Persona: it stops, and its package, storage, and secrets go, and its runtime deletes what it keeps of it. The other version of a pair stays installed in the pair's place with its grant, storage, and switch, and the pair's record goes. Built-in plugins cannot be removed, only switched off. Throws when the Keychain or the file system refuses, with the plugin still installed.
    public func remove(_ id: PluginID) throws {
        guard packages[id] != nil, let installed = plugins.first(where: { $0.id == id }) else { return }
        badges[id] = nil
        stop(id)
        try secrets(for: id).removeAll()
        storages.removeValue(forKey: id)?.discardChanges()
        let folder = Self.folder(of: id, in: directory)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        runtimes[installed.kind]?.remove(installed)
        packages[id] = nil
        let entryIndex = installs.firstIndex { $0.id == id.rawValue }
        installs.removeAll { $0.id == id.rawValue }
        choices.removeAll { $0.id == id.rawValue }
        dropRecords(naming: [id])
        var next = plugins
        if let index = next.firstIndex(where: { $0.id == id }) {
            next.remove(at: index)
            // The other version takes the pair's place.
            if let counterpart = installed.counterpart {
                if let from = next.firstIndex(where: { $0.id == counterpart }), from > index { next.insert(next.remove(at: from), at: index) }
                if let entryIndex, let from = installs.firstIndex(where: { $0.id == counterpart.rawValue }), from > entryIndex { installs.insert(installs.remove(at: from), at: entryIndex) }
            }
        }
        saveList()
        failures[id] = nil
        setPlugins(next)
    }

    // MARK: Deleting the Persona

    /// Stops the plugins for good as the session deletes the Persona: they leave the list, so their contributions go and nothing starts them again, their running instances stop, and the storage changes that have not reached the files are dropped, since the Persona's folder goes at the next launch.
    public func close() {
        for id in Array(running.keys) { stop(id) }
        badges = [:]
        engineVersions = []
        plugins = []
        storages.values.forEach { $0.discardChanges() }
        storages = [:]
    }

    /// Deletes what the plugins of a deleted Persona left, before any manager of the Persona exists: their secrets in the Keychain and the Persona's folder in `directory`, the app's Application Support folder. Reports whether all of it is gone; data that was never there counts as gone.
    nonisolated public static func removeData(ofPersona persona: PersonaID, in directory: URL) -> Bool {
        removeData(ofPersona: persona, in: directory, secretStore: PluginKeychain())
    }

    nonisolated static func removeData(ofPersona persona: PersonaID, in directory: URL, secretStore: any PluginSecretStore) -> Bool {
        let secretsRemoved = (try? secretStore.removeSecrets(service: nil, accountPrefix: ScopedPluginSecrets.accountPrefix(of: persona))) != nil
        let folder = folder(ofPersona: persona, in: directory)
        let folderRemoved = !FileManager.default.fileExists(atPath: folder.path) || (try? FileManager.default.removeItem(at: folder)) != nil
        return secretsRemoved && folderRemoved
    }

    // MARK: Folders

    /// The Persona's folder, `Plugins/<persona id>/` in `directory`, the app's Application Support folder.
    nonisolated private static func folder(ofPersona persona: PersonaID, in directory: URL) -> URL {
        directory.appendingPathComponent("Plugins", isDirectory: true).appendingPathComponent(persona.uuidString, isDirectory: true)
    }

    /// `<plugin id>/` in the Persona's folder `directory`, which holds the plugin's package and storage.
    private static func folder(of id: PluginID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// `<plugin id>/package/` in the Persona's folder `directory`.
    private static func packageFolder(of id: PluginID, in directory: URL) -> URL {
        folder(of: id, in: directory).appendingPathComponent("package", isDirectory: true)
    }

    // MARK: Contributions

    /// Runs a command of an enabled plugin, starting the plugin first if it has not started. The plugin receives the invocation's tab without what its grant does not cover. A command that fails, or whose plugin fails to start, beeps.
    public func run(_ command: PluginCommandRef, _ invocation: PluginInvocation) async {
        guard let installed = enabledPlugin(command.plugin), installed.manifest.contributions.commands.contains(where: { $0.id == command.command }) else { return }
        var redacted = invocation
        redacted.tab = invocation.tab?.redacted(for: installed.grant)
        do {
            try await start(installed)?.run(command.command, redacted)
        } catch {
            NSSound.beep()
        }
    }

    /// The panel of a sidebar item whose action is `.panel`, from its plugin, which starts first if it has not started. Nil, with a beep, when the plugin offers no panel for the item or fails to start.
    public func panel(for item: Attributed<PluginSidebarItem>) async -> NSViewController? {
        guard item.item.action == .panel, let installed = enabledPlugin(item.plugin), installed.manifest.contributions.sidebarItems.contains(item.item) else { return nil }
        if let panel = try? await start(installed)?.panel(for: item.item.id) { return panel }
        NSSound.beep()
        return nil
    }

    /// The badge the item's plugin set on it, if any.
    public func badge(on item: Attributed<PluginSidebarItem>) -> String? {
        badges[item.plugin]?[item.item.id]
    }

    /// Only an enabled plugin's own sidebar items take a badge.
    fileprivate func setBadge(_ text: String?, onSidebarItem id: String, of plugin: PluginID) {
        guard let installed = enabledPlugin(plugin), installed.manifest.contributions.sidebarItems.contains(where: { $0.id == id }) else { return }
        badges[plugin, default: [:]][id] = text?.isEmpty == false ? text : nil
    }

    // MARK: Page scripts

    /// Whether a page script of the enabled plugin runs in the main frame at `url`: the script's patterns and one of the plugin's granted sites cover the address.
    public func pageScriptsCover(_ url: URL, of id: PluginID) -> Bool {
        guard let installed = enabledPlugin(id), installed.grant.covers(url) else { return false }
        return installed.manifest.contributions.pageScripts.contains { $0.covers(url) }
    }

    /// Passes a value that a page script in `tab` sent to its plugin, starting the plugin first if it has not started. The value reaches the plugin only while the plugin is enabled and its granted sites cover the sending frame's document, and the plugin receives the tab without what its grant does not cover. Returns the plugin's reply as JSON text, or nil when there is none or the plugin fails.
    public func receive(_ message: EnginePageScriptMessage, from tab: PluginTab) async -> String? {
        guard let installed = plugins.first(where: { $0.id.pageScriptWorld == message.world }), installed.isEnabled,
              let frameURL = message.frameURL, installed.grant.covers(frameURL),
              let body = try? JSONDecoder().decode(PluginValue.self, from: Data(message.json.utf8)) else { return nil }
        let page = PluginPageMessage(tab: tab.redacted(for: installed.grant), frameURL: frameURL, isMainFrame: message.isMainFrame, body: body)
        do {
            guard let reply = try await start(installed)?.receive(page) else { return nil }
            return String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        } catch {
            return nil
        }
    }

    // MARK: Settings

    /// The value of a plugin's setting: the user's, or the default for one the user has not changed or whose stored value no longer suits the field. Nil for a secret setting, whose value stays in the Keychain.
    public func value(of setting: PluginSetting, for id: PluginID) -> PluginValue? {
        guard let stored = storage(for: id).settingValue(forKey: setting.key), setting.kind.accepts(stored) else { return setting.kind.defaultValue }
        return stored
    }

    /// nil restores the default. Throws as `PluginStorage.setValue(_:forKey:)` does, since setting values share the plugin's storage.
    public func setValue(_ value: PluginValue?, of setting: PluginSetting, for id: PluginID) throws {
        objectWillChange.send()
        try storage(for: id).setSettingValue(value, forKey: setting.key)
    }

    /// Whether the Keychain holds a value for a secret setting. It reads only whether the item exists, so macOS does not ask for the keychain password.
    public func hasSecret(_ setting: PluginSetting, for id: PluginID) throws -> Bool {
        try secrets(for: id).containsSecret(forKey: setting.key)
    }

    /// nil deletes the Keychain item.
    public func setSecret(_ secret: String?, of setting: PluginSetting, for id: PluginID) throws {
        objectWillChange.send()
        try secrets(for: id).setSecret(secret, forKey: setting.key)
    }

    /// The setting `key` of the plugin's manifest, as `PluginContext.setting(_:)` reads it.
    fileprivate func setting(_ key: String, of id: PluginID) -> PluginValue? {
        guard let setting = plugins.first(where: { $0.id == id })?.manifest.contributions.settings.first(where: { $0.key == key }) else { return nil }
        return value(of: setting, for: id)
    }

    // MARK: Running plugins

    /// The plugin while it is enabled and its runtime can run it.
    private func enabledPlugin(_ id: PluginID) -> InstalledPlugin? {
        plugins.first { $0.id == id && $0.isEnabled && $0.unavailability == nil }
    }

    /// The running plugin, started first if needed, or nil when it stopped while it activated. Commands, panels, and page script values that arrive while the plugin activates wait for the same activation, and later ones reach the plugin at once. A failed activation leaves the plugin stopped, so its next use starts it again.
    private func start(_ installed: InstalledPlugin) async throws -> (any Plugin)? {
        let started: RunningPlugin
        if let existing = running[installed.id] {
            // Waiting again, even for a finished activation, could let a script plugin stop at its idle limit before the use reaches it.
            if existing.isActive { return existing.plugin }
            started = existing
        } else {
            guard let plugin = makePlugin(installed) else { return nil }
            let context = makeContext(for: installed)
            started = RunningPlugin(plugin: plugin, context: context, activation: Task { try await plugin.activate(in: context) })
            running[installed.id] = started
        }
        do {
            try await started.activation.value
        } catch {
            // The failed instance is dropped, so whatever it left running cannot act for the plugin.
            started.context.end()
            if running[installed.id]?.plugin === started.plugin { running[installed.id] = nil }
            throw error
        }
        guard running[installed.id]?.plugin === started.plugin else { return nil }
        running[installed.id]?.isActive = true
        return started.plugin
    }

    /// A new instance of the plugin: of its built-in type, of the script plugin in its package, or from its kind's runtime. A script plugin's instance that stops on its own leaves, so that the next use starts a new one, and its failures count towards switching the plugin off.
    private func makePlugin(_ installed: InstalledPlugin) -> (any Plugin)? {
        let id = installed.id
        if let type = builtIns[id] { return type.init() }
        guard let package = packages[id] else { return nil }
        guard package.kind == .script else { return runtimes[package.kind]?.makePlugin(installed) }
        let plugin = ScriptPlugin(package: package, limits: scriptLimits)
        plugin.onStop = { [weak self, weak plugin] reason in
            guard let self, let plugin, running[id]?.plugin === plugin else { return }
            stop(id)
            if case let .failed(failure) = reason { recordFailure(failure, of: id) }
        }
        return plugin
    }

    /// Switches the plugin off at its third failure within `failureWindow`, with the last one's reason for Settings.
    private func recordFailure(_ reason: String, of id: PluginID) {
        let now = Date()
        let recent = (failures[id] ?? []).filter { now.timeIntervalSince($0) < Self.failureWindow } + [now]
        failures[id] = recent
        guard recent.count >= Self.failureLimit else { return }
        setEnabled(false, for: [id], failure: "Arch switched the plugin off after it failed three times within five minutes. \(reason)")
    }

    func makeContext(for installed: InstalledPlugin) -> ScopedPluginContext {
        ScopedPluginContext(manager: self, pluginID: installed.id, personaID: persona, grant: installed.grant,
                            storage: ScopedPluginStorage(file: storage(for: installed.id)), secrets: secrets(for: installed.id))
    }

    /// `<plugin id>/storage.json` in the Persona's folder.
    private func storage(for id: PluginID) -> PluginStorageFile {
        if let storage = storages[id] { return storage }
        let storage = PluginStorageFile(fileURL: Self.folder(of: id, in: directory).appendingPathComponent("storage.json"))
        storages[id] = storage
        return storage
    }

    private func secrets(for id: PluginID) -> ScopedPluginSecrets {
        ScopedPluginSecrets(store: secretStore, pluginID: id, personaID: persona)
    }
}

/// `plugins.json` in the Persona's folder: whether each plugin the user switched on or off is enabled, and the plugins the user installed. A built-in plugin without a choice follows `BuiltInPlugin.isOnByDefault`, and an installed one is off.
struct PluginListFile: Codable {
    static let name = "plugins.json"

    struct Choice: Codable {
        /// The plugin's identifier as `PluginID` writes it.
        var id: String
        var isEnabled: Bool
    }

    /// An installed plugin, whose manifest its package in `<id>/package/` holds. The file names its origin with `source`, the folder or archive the user installed it from, or with `generated`, how AI wrote it.
    struct Install: Codable {
        /// The plugin's identifier as `PluginID` writes it.
        var id: String
        /// A file or AI, never the app: built-in plugins are not installed.
        var origin: PluginOrigin
        var grant: PluginGrant
        var installedAt: Date
        /// What each engine that checked the package found, by engine name as `EngineKind` writes it. Names stay text, so that the answers of engines this build does not know survive its writes. Absent from entries of builds before engine checks and of kinds that run alike on every engine.
        var engineChecks: [String: EngineCheck]?
        /// The engines whose note asking for a version of the plugin the user dismissed, by engine name, including names this build does not know. Absent where the user dismissed none.
        var dismissedVersionNotes: [String]?

        private enum CodingKeys: String, CodingKey {
            case id, source, generated, grant, installedAt, engineChecks, dismissedVersionNotes
        }

        init(id: String, origin: PluginOrigin, grant: PluginGrant, installedAt: Date, engineChecks: [String: EngineCheck]?) {
            self.id = id
            self.origin = origin
            self.grant = grant
            self.installedAt = installedAt
            self.engineChecks = engineChecks
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            if let composition = try container.decodeIfPresent(PluginComposition.self, forKey: .generated) {
                origin = .generated(composition)
            } else {
                origin = .file(try container.decode(URL.self, forKey: .source))
            }
            grant = try container.decode(PluginGrant.self, forKey: .grant)
            installedAt = try container.decode(Date.self, forKey: .installedAt)
            engineChecks = try container.decodeIfPresent([String: EngineCheck].self, forKey: .engineChecks)
            dismissedVersionNotes = try container.decodeIfPresent([String].self, forKey: .dismissedVersionNotes)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            switch origin {
            case let .file(url): try container.encode(url, forKey: .source)
            case let .generated(composition): try container.encode(composition, forKey: .generated)
            // Nothing installs a built-in plugin.
            case .bundled: break
            }
            try container.encode(grant, forKey: .grant)
            try container.encode(installedAt, forKey: .installedAt)
            try container.encodeIfPresent(engineChecks, forKey: .engineChecks)
            try container.encodeIfPresent(dismissedVersionNotes, forKey: .dismissedVersionNotes)
        }
    }

    /// Whether an engine runs a package, with the version of the engine's extension runtime that gave the answer.
    struct EngineCheck: Codable {
        var runs: Bool
        var version: String
    }

    /// An install as the file holds it. One this build cannot read, such as one whose grant holds a permission that a newer build added, stays as the file has it, so that writing the file keeps it.
    enum InstallEntry: Codable {
        case readable(Install)
        case unreadable(PluginValue)

        /// The plugin's identifier, if the entry names one.
        var id: String? {
            switch self {
            case let .readable(install):
                return install.id
            case let .unreadable(.object(fields)):
                guard case let .string(id)? = fields["id"] else { return nil }
                return id
            case .unreadable:
                return nil
            }
        }

        init(from decoder: any Decoder) throws {
            if let install = try? Install(from: decoder) {
                self = .readable(install)
            } else {
                self = .unreadable(try PluginValue(from: decoder))
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case let .readable(install): try install.encode(to: encoder)
            case let .unreadable(entry): try entry.encode(to: encoder)
            }
        }
    }

    var choices: [Choice]
    /// Absent from files of builds before installed plugins.
    var installed: [InstallEntry]?
    /// The pairs of engine versions in the order the user made them, each as an object from engine name to plugin identifier, including those this build ignores. Absent from files without pairs.
    var engineVersions: [[String: String]]?
}

/// The context the manager gives each plugin instance it starts. It acts for the instance until the manager ends it, when the instance stops or its activation fails. From then on its storage and secrets only read, its actions throw `PluginError.stopped`, and its badges do nothing, so tasks the instance left running cannot act for the plugin.
@MainActor
final class ScopedPluginContext: PluginContext {
    let pluginID: PluginID
    let personaID: PersonaID
    let grant: PluginGrant
    private let scopedStorage: ScopedPluginStorage
    private let scopedSecrets: ScopedPluginSecrets
    private weak var manager: PluginManager?
    private var hasEnded = false

    init(manager: PluginManager, pluginID: PluginID, personaID: PersonaID, grant: PluginGrant, storage: ScopedPluginStorage, secrets: ScopedPluginSecrets) {
        self.manager = manager
        self.pluginID = pluginID
        self.personaID = personaID
        self.grant = grant
        scopedStorage = storage
        scopedSecrets = secrets
    }

    var storage: any PluginStorage { scopedStorage }
    var secrets: any PluginSecrets { scopedSecrets }

    /// Stops the context, its storage, and its secrets from acting for the instance.
    func end() {
        hasEnded = true
        scopedStorage.end()
        scopedSecrets.end()
    }

    func setting(_ key: String) -> PluginValue? {
        manager?.setting(key, of: pluginID)
    }

    func setBadge(_ text: String?, onSidebarItem id: String) {
        guard !hasEnded else { return }
        manager?.setBadge(text, onSidebarItem: id, of: pluginID)
    }

    func copyToClipboard(_ text: String) throws {
        guard !hasEnded else { throw PluginError.stopped }
        try require(.clipboard)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func require(_ permission: PluginPermission) throws {
        guard grant.permissions.contains(permission) else { throw PluginError.permissionDenied(permission) }
    }
}
