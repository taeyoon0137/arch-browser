// The plugins of one Persona. The manager registers the built-in plugins and the plugins the user installed, script plugins and those of the kinds whose runtimes the app supplies, keeps which of them the user switched on or off and what it installed in `plugins.json`, exposes the contributions of the enabled ones, starts a plugin's code only when one of its commands runs, one of its panels opens, or one of its page scripts sends it a value, and keeps each plugin's data in the Persona's folder and its secrets in the Keychain. It stages plugins from the files the user chooses and script plugins from the files AI writes, installs, updates, and removes installed plugins, records which engines run the packages of kinds that engines check, tells each runtime which of its plugins are enabled, and switches off a script plugin whose background script fails three times within five minutes.
import AppKit
import ARCHEngine
import Combine

/// A plugin the manager knows, with its grant and whether it is enabled.
public struct InstalledPlugin: Identifiable, Hashable, Sendable {
    public var id: PluginID { manifest.id }
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

    /// The engines a web extension runs on: those whose current answer runs its package, less those where it failed to start. Empty for other kinds.
    public var engines: Set<EngineKind> {
        Set(engineChecks.filter(\.value).keys).subtracting(engineFailures.keys)
    }

    /// Where the plugin runs, as Settings says it, such as "Runs on WebKit tabs.", once an engine has checked its package, or "No engine on this Mac runs it." when every engine that checked it refuses it. Nil while it starts on none of the engines that run it, whose failures say why.
    public var enginesNote: String? {
        guard !engineChecks.isEmpty else { return nil }
        if let note = PluginPackage.runsNote(on: engines) { return note }
        return engineChecks.values.contains(true) ? nil : "No engine on this Mac runs it."
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
    /// The built-in plugins in the order the app listed them, then the installed plugins in the order the user installed them.
    @Published public private(set) var plugins: [InstalledPlugin] {
        didSet {
            contributions = PluginContributionIndex(plugins)
            runEnabledPlugins()
        }
    }
    @Published public private(set) var contributions: PluginContributionIndex
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

    /// `directory` is the app's Application Support folder. Built-in plugins get everything their manifests ask for. Of two built-in plugins with the same identifier, the first counts. The installed plugins follow, each read from its package, script plugins by the manager and other kinds by their `runtimes`; one whose package or `plugins.json` entry does not read, as one of a kind without a runtime, stays in the file but out of the list. The runtimes learn the enabled plugins of their kinds at once.
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
                  package.manifest.id == id else { continue }
            packages[id] = package
            let runtime = self.runtimes[package.kind]
            plugins.append(Self.installedPlugin(package, grant: install.grant, isEnabled: choices.first { $0.id == install.id }?.isEnabled ?? false,
                                                installedAt: install.installedAt, unavailability: runtime?.unavailability,
                                                engineChecks: Self.currentChecks(install.engineChecks, engines: runtime?.engines ?? [:])))
        }
        self.plugins = plugins
        self.builtIns = types
        self.packages = packages
        self.choices = choices
        self.installs = installs
        contributions = PluginContributionIndex(plugins)
        // Packages that were under review when the app last quit cannot be installed any more.
        try? FileManager.default.removeItem(at: stagingDirectory)
        for runtime in self.runtimes.values {
            runtime.onFailure = { [weak self] id, reason in self?.setEnabled(false, for: id, failure: reason) }
            runtime.onCheck = { [weak self] id, checks in self?.record(checks, for: id) }
            runtime.onEngineFailure = { [weak self] id, engine, reason in self?.recordEngineFailure(reason, of: id, on: engine) }
            runtime.onEnginesChange = { [weak self, kind = runtime.kind] in self?.readEngineChecks(of: kind) }
        }
        runEnabledPlugins()
    }

    /// The installed package as the list shows it, with the part of `grant` that its manifest asks for, with why its runtime cannot run it, if it cannot, and with the current answers of the engines that checked it.
    private static func installedPlugin(_ package: PluginPackage, grant: PluginGrant, isEnabled: Bool, installedAt: Date, unavailability: String?,
                                        engineChecks: [EngineKind: Bool]) -> InstalledPlugin {
        InstalledPlugin(kind: package.kind, manifest: package.manifest, origin: package.origin, packageURL: package.rootURL, grant: grant.limited(to: package.manifest),
                        isEnabled: isEnabled, installedAt: installedAt, unavailability: unavailability, engineChecks: engineChecks)
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

    /// Records the choice in `plugins.json`. Switching a plugin off removes its contributions, so its page scripts stop at each tab's next load and their values no longer reach it, drops its badges, and stops its code.
    public func setEnabled(_ isEnabled: Bool, for id: PluginID) {
        setEnabled(isEnabled, for: id, failure: nil)
    }

    /// `failure` says why the manager switches the plugin off, for Settings.
    private func setEnabled(_ isEnabled: Bool, for id: PluginID, failure: String?) {
        guard let index = plugins.firstIndex(where: { $0.id == id }), plugins[index].isEnabled != isEnabled else { return }
        recordChoice(isEnabled, for: id)
        saveList()
        var plugin = plugins[index]
        plugin.isEnabled = isEnabled
        plugin.failure = failure
        // Switching a plugin on tries again the engines where it failed to start; the runtime checks again the package of one that every engine refused.
        if isEnabled { plugin.engineFailures = [:] }
        plugins[index] = plugin
        failures[id] = nil
        if !isEnabled {
            badges[id] = nil
            stop(id)
        }
    }

    /// A new choice for a plugin replaces its old one.
    private func recordChoice(_ isEnabled: Bool, for id: PluginID) {
        choices.removeAll { $0.id == id.rawValue }
        choices.append(PluginListFile.Choice(id: id.rawValue, isEnabled: isEnabled))
    }

    /// Choices and installs are few and rare, so each writes the file at once.
    private func saveList() {
        guard let data = try? JSONEncoder().encode(PluginListFile(choices: choices, installed: installs)) else { return }
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

    /// Copies a folder or `.zip` archive the user chose into the staging folder and reads its package there for the install sheet, without running any of it: a script plugin's, or one of a kind that a runtime reads. The engines that run the kind on this Mac check the package, and the installed plugin it would update, in the engines that have no current answer for it. Throws `PluginError.invalidPackage` or `.unsupportedAPIVersion` for a package Arch cannot install, for one whose identifier `checkInstallable(_:of:)` refuses, and, with the first engine's reason, for one that every engine refuses. A staged package ends with `install(_:grant:isEnabled:)` or `discard(_:)`.
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
                await checkInstalledPlugin(updatedBy: package, in: runtime)
                package.engineChecks = await runtime.check(packageAt: package.rootURL)
                if let refusal = Self.refusal(in: package.engineChecks) { throw PluginError.invalidPackage(refusal) }
            }
        } catch {
            discard(package)
            throw error
        }
        return package
    }

    /// Checks the installed plugin that the package would update, on or off, in the runtime's engines that have no current answer for it, and records the answers.
    private func checkInstalledPlugin(updatedBy package: PluginPackage, in runtime: any PluginRuntime) async {
        guard let installed = plugins.first(where: { $0.id == package.manifest.id && $0.kind == package.kind }), let packageURL = installed.packageURL else { return }
        let unanswered = Set(runtime.engines.keys).subtracting(installed.engineChecks.keys)
        guard !unanswered.isEmpty else { return }
        record(await runtime.check(packageAt: packageURL).filter { unanswered.contains($0.key) }, for: installed.id)
    }

    /// Throws `PluginError.invalidPackage` for an identifier that no installed plugin of `kind` may have: a built-in plugin's, one of earlier builds that `PluginIdentifierMigration` renames at launch, an installed plugin's of another kind, which an update cannot turn into this kind, or the name of `plugins.json` or of the copy kept of it when it does not decode, which the plugin's folder would take in the Persona's folder.
    private func checkInstallable(_ id: PluginID, of kind: PluginKind) throws {
        guard builtIns[id] == nil else { throw PluginError.invalidPackage("A plugin built into Arch has the identifier \(id.rawValue).") }
        if let renamed = PluginIdentifierMigration.renamed(id.rawValue) {
            throw PluginError.invalidPackage("Arch renames the identifier \(id.rawValue) to \(renamed) at launch, so no plugin can have it as its identifier.")
        }
        if let installed = packages[id], installed.kind != kind {
            throw PluginError.invalidPackage("An installed plugin of another kind has the identifier \(id.rawValue).")
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

    /// Installs a staged package in the Persona with the part of `grant` that its manifest asks for, enabled or not as `isEnabled` says. A package with an installed plugin's identifier updates it: the new package replaces the old one, the plugin keeps its place, storage, and secrets, and its running instance stops, so that its next use starts the new code.
    public func install(_ package: PluginPackage, grant: PluginGrant, isEnabled: Bool) throws {
        let id = package.manifest.id
        try checkInstallable(id, of: package.kind)
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
        let engines = runtimes[installed.kind]?.engines ?? [:]
        let checks = Self.fileChecks(package.engineChecks, engines: engines)
        let install = PluginListFile.Install(id: id.rawValue, origin: package.origin, grant: grant.limited(to: package.manifest), installedAt: Date(),
                                             engineChecks: checks.isEmpty ? nil : checks)
        if let index = installs.firstIndex(where: { $0.id == install.id }) {
            installs[index] = .readable(install)
        } else {
            installs.append(.readable(install))
        }
        recordChoice(isEnabled, for: id)
        saveList()
        failures[id] = nil
        let plugin = Self.installedPlugin(installed, grant: install.grant, isEnabled: isEnabled, installedAt: install.installedAt, unavailability: runtimes[installed.kind]?.unavailability,
                                          engineChecks: Self.currentChecks(install.engineChecks, engines: engines))
        if let index = plugins.firstIndex(where: { $0.id == id }) {
            plugins[index] = plugin
        } else {
            plugins.append(plugin)
        }
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
            setEnabled(false, for: id, failure: reason)
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
        setEnabled(false, for: id, failure: EngineKind.allCases.compactMap { plugin.engineFailures[$0] }.joined(separator: "\n"))
    }

    /// Deletes an installed plugin from the Persona: it stops, and its package, storage, and secrets go, and its runtime deletes what it keeps of it. Built-in plugins cannot be removed, only switched off. Throws when the Keychain or the file system refuses, with the plugin still installed.
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
        installs.removeAll { $0.id == id.rawValue }
        choices.removeAll { $0.id == id.rawValue }
        saveList()
        failures[id] = nil
        plugins.removeAll { $0.id == id }
    }

    // MARK: Deleting the Persona

    /// Stops the plugins for good as the session deletes the Persona: they leave the list, so their contributions go and nothing starts them again, their running instances stop, and the storage changes that have not reached the files are dropped, since the Persona's folder goes at the next launch.
    public func close() {
        for id in Array(running.keys) { stop(id) }
        badges = [:]
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
        setEnabled(false, for: id, failure: "Arch switched the plugin off after it failed three times within five minutes. \(reason)")
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

        private enum CodingKeys: String, CodingKey {
            case id, source, generated, grant, installedAt, engineChecks
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
