// The plugins of one Persona. The manager registers the built-in plugins and the plugins the user installed, script plugins and those of the kinds whose runtimes the app supplies, keeps which of them the user switched on or off and what it installed in `plugins.json`, exposes the contributions of the enabled ones, starts a plugin's code only when one of its commands runs, one of its panels opens, one of its page scripts sends it a value, an event its manifest lists arrives from the Persona's browser events, or the user changes one of its settings while its manifest asks for that, and keeps each plugin's data in the Persona's folder and its secrets in the Keychain. It stages plugins from the files the user chooses and script plugins from the files AI writes, installs, updates, and removes installed plugins, records which engines run the packages of kinds that engines check, keeps two web extension plugins that are versions of one extension as a pair with one engine each, tells each runtime which of its plugins are enabled, and switches off a script plugin whose background script fails three times within five minutes. It registers the AI feature of each enabled plugin with `ai` and runs the bus event listeners of those with bus events as steps of the shared hook scheduler.
import AI
import AppKit
import ARCHEngine
import Combine
import Events
import UniformTypeIdentifiers

/// A plugin the manager knows, with its grant and whether it is enabled.
public struct InstalledPlugin: Identifiable, Hashable, Sendable {
    /// The install entry's identifier, which names the plugin's folder, choice, storage, and Keychain items: the manifest's, or, for a version that joined a plugin whose version has the same identifier, that followed by `.webkit` or `.chromium`. A built-in plugin's is its manifest's.
    public var id: PluginID { entryID ?? manifest.id }
    public var kind: PluginKind = .builtIn
    public var manifest: PluginManifest
    public var origin: PluginOrigin = .bundled
    /// What the signatures of the installed package's `.crx` file proved, as its install entry records it (`docs/web-store.md`, Package proof). Nil for other packages, for a `.crx` file installed before Arch checked signatures, and for a proof this build does not know.
    public var proof: PluginProof?
    /// Whether the install entry names a `.crx` file with `source`, as an install before Arch checked signatures does, so that installing the file again gives the plugin its proof, as the native app gate's sentence says.
    public var predatesProof = false
    /// The folder of the installed package; nil for a built-in plugin.
    public var packageURL: URL?
    public var grant: PluginGrant
    public var isEnabled: Bool
    /// When the user installed the plugin; nil for a built-in plugin.
    public var installedAt: Date?
    /// Why the manager switched the plugin off in this run: after repeated failures of its background script, because it failed to start on every engine it ran on, or because every engine of its kind's runtime refuses its package. Settings shows it until the plugin is switched on again.
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

    /// The engines, in the order of `EngineKind`, for which Settings offers Install <Engine> Version…: each of the engines that a pair divides (`PluginEngineVersions.engines`) that is among `running`, the engines that run the kind on this Mac, and on which the plugin does not run, after a refusal, after a failure to start, or before the engine has checked its package, while it runs on another engine. None in a pair, and none for a plugin that runs on every such engine.
    public func versionEngines(among running: Set<EngineKind>) -> [EngineKind] {
        guard counterpart == nil else { return [] }
        return PluginEngineVersions.engines.filter { engine in running.contains(engine) && !engines.contains(engine) && engines.contains { $0 != engine } }
    }

    /// The engine whose version the plugin asks for, by the rule in Engine versions ▸ Guidance: one of `running` that has a current answer for the package and on which the plugin does not run, a failure to start counting, while it runs on another, and whose note the user has not dismissed. Nil in a pair.
    public func missingEngine(among running: Set<EngineKind>) -> EngineKind? {
        versionEngines(among: running).first { engineChecks[$0] != nil && !engines.contains($0) && !dismissedVersionNotes.contains($0) }
    }

    /// What the plugin may do, one sentence each, as Settings states it in the install sheet's order: the grant's permissions, the data kinds that come with `ai` and the API permissions that come with a web extension, then the grant's sites and, for `whenInvoked`, its site access.
    public var accessSummaries: [String] {
        permissionSummaries + includedSummaries + grant.sites.map(\.accessSummary) + grant.siteAccessSummaries
    }

    /// The sentence of each permission of the grant, in a fixed order.
    private var permissionSummaries: [String] {
        PluginPermission.allCases.filter(grant.permissions.contains).map(\.summary)
    }

    /// The sentences of what comes with the grant: the data kinds that its AI requests carry and a web extension's other API permissions.
    private var includedSummaries: [String] {
        [grant.permissions.contains(.ai) ? manifest.aiDataSummary : nil, manifest.extensionPermissionsSummary].compactMap { $0 }
    }

    /// The most sites whose sentences Settings lists among `accessSummaries`; with more, it states them in one (`accessBrief`).
    public static let listedSiteLimit = 3

    /// `accessSummaries` as Settings states them while the grant has more than `listedSiteLimit` sites, with every site's sentence behind a disclosure, or nil with fewer: each permission's sentence and those that come with the grant, which are few and stay in view, such as the one for exchanging messages with apps on this Mac, and in place of the sites' sentences one that names them by the broadest (`MatchPattern.briefAccessSummary(of:)`), such as "Run scripts on pages from every .com website and 3 more", followed by the site access's sentence for `whenInvoked`.
    public var accessBrief: [String]? {
        guard grant.sites.count > Self.listedSiteLimit, let sites = MatchPattern.briefAccessSummary(of: grant.sites) else { return nil }
        return permissionSummaries + includedSummaries + [sites] + grant.siteAccessSummaries
    }
}

/// The proof gate on native apps, which the app supplies for web extensions (`docs/password-managers.md`, Proof gate): a version of an extension reaches a native app through one of Arch's links to another browser's host manifest only when Arch has proof of its identifier, since a package can copy another extension's public key and the native app trusts the identifier that the browser passes it.
@MainActor
public protocol PluginNativeAppGate: AnyObject {
    /// Looks for native apps, unless Arch has looked in this run.
    func update() async
    /// The gate's sentence for a version of the web extension with `manifest` and `proof` whose identifier a manifest behind one of Arch's links allows, or nil for a version with proof and for one that no such manifest allows; `predatesProof` gives the sentence that asks for a reinstall (`InstalledPlugin.predatesProof`). Whether the version's grant has `nativeMessaging` is the caller's question.
    func refusal(of manifest: PluginManifest, proof: PluginProof?, predatesProof: Bool) -> String?
}

@MainActor
public final class PluginManager: ObservableObject {
    /// The start of the identifiers of Arch's own plugins: those built into it and, under `PluginComposer.identifierPrefix`, those that AI writes.
    nonisolated static let archIdentifierPrefix = "xyz.taeyoon.arch."
    /// A script plugin whose background script fails this often within `failureWindow` is switched off.
    private static let failureLimit = 3
    private static let failureWindow: TimeInterval = 5 * 60

    /// The Persona whose plugins the manager keeps.
    public let persona: PersonaID
    /// `Plugins/<persona id>/` in the app's Application Support folder, with `plugins.json`, a folder for each plugin named by its identifier, `Staging/` for packages under review, and each runtime's own file.
    private let directory: URL
    /// The built-in plugins in the order the app listed them, then the installed plugins in the order the user installed them, where the remaining version of a pair takes the place of the pair. Each version of a pair has its counterpart and its engine.
    @Published public private(set) var plugins: [InstalledPlugin] {
        didSet {
            contributions = PluginContributionIndex(plugins, disabledCommands: disabledCommands)
            pruneSiteAccess()
            runEnabledPlugins()
            registerAIFeatures()
        }
    }
    @Published public private(set) var contributions: PluginContributionIndex
    /// The page scripts of the plugins that reach their sites `whenInvoked` and have access in a tab, by tab, which change as an access begins or ends. Each runs only on the host of the tab's access, besides its patterns and the granted sites. An access that no longer holds stays here until its next check, so the session gives a tab the scripts of `accessPageScripts(forTab:)` after the Persona's.
    @Published public private(set) var tabPageScripts: [UUID: [EnginePageScript]] = [:]
    /// The tabs where each plugin that reaches its sites `whenInvoked` has access, by plugin and tab.
    private var siteAccess: [PluginID: [UUID: TabSiteAccess]] = [:]
    /// The pairs whose versions are both listed, in the order the user made them.
    @Published public private(set) var engineVersions: [PluginEngineVersions] = []
    /// Why the last write of `plugins.json` failed, as Settings states it, while the file lacks changes of this run: switches, joins, separations, dismissed notes, removals, and the engines' answers, which keep their effect until Arch quits. Each change writes the whole file again, so the first write that succeeds saves them all and clears it. An install whose write fails throws instead and leaves nothing to save.
    @Published public private(set) var listWriteFailure: String?
    /// The badges the plugins set, by plugin and sidebar item.
    @Published private var badges: [PluginID: [String: String]] = [:]
    @Published public private(set) var panelRequest: (plugin: PluginID, item: String, nonce: UUID)?
    private var disabledCommands: [PluginID: Set<String>] = [:]
    private var lastNotification: [PluginID: Date] = [:]
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
    /// The SHA-256 digest of the key whose proof in a `.crx` file shows that the Web Store published it: the store's, or a test's own.
    private let publisherKeyDigest: Data
    /// Plugins whose code has started. Each starts at its first command, panel, or page script value and runs until it stops: when the user switches it off, updates it, removes it, or deletes the Persona, or the app quits, and a script plugin also when it stops on its own.
    private var running: [PluginID: RunningPlugin] = [:]
    /// The storage of each plugin, made when the plugin starts or its settings are first read. It outlives a failed activation, so the plugin's next start finds the changes that have not reached the file.
    private var storages: [PluginID: PluginStorageFile] = [:]
    /// When each script plugin's background script failed in the last `failureWindow`.
    private var failures: [PluginID: [Date]] = [:]
    /// Whether the session closed the manager as it deleted the Persona, after which it stages, installs, and stores nothing, and callers that fetch a package for it stop before they ask for or download one.
    public private(set) var isClosed = false
    /// Set by the app: the proof gate on native apps, which staging asks to look for native apps before it checks a web extension that asks for `nativeMessaging`, the review shows in a package's Chromium line, and joins follow. Nil gates nothing.
    public var nativeAppGate: (any PluginNativeAppGate)?
    /// Reaches the Persona's tabs for the plugins' tab calls; without one, plugins see no tabs.
    private let browserHost: (any PluginBrowserHost)?
    /// The Persona's events on the session's bus, which reach the plugins whose manifests list their kinds.
    private var events: BrowserEventSubscription?
    /// The events each plugin received in the last minute, which loop protection's rate caps (`docs/hooks.md`, Plugins).
    private var eventLimiter = BrowserEventRateLimiter()
    /// When each plugin opened the tabs it opened in the last minute, which `tabOpenLimit` caps.
    private var tabOpenings: [PluginID: [Date]] = [:]
    /// The AI interface that the plugins with `ai` send their requests through, whose hook scheduler runs their hooks; without one, they get no AI and their events arrive as for other plugins.
    private let ai: AIService?
    /// The features this manager registered in `ai`, those of its enabled plugins with `ai`, by identifier.
    private var aiFeatures: [AIFeatureID: AIFeature] = [:]
    /// The managers of every Persona, which share a feature when they hold plugins with one identifier.
    private static let liveManagers = NSHashTable<PluginManager>.weakObjects()
    /// Each plugin's hook steps, which run one at a time.
    private var hookQueues: [PluginID: PluginHookQueue] = [:]
    /// The setting changes that wait to settle before their plugins hear of them, by plugin and setting key.
    private var settingChanges: [PluginID: [String: PendingSettingChange]] = [:]
    /// The order of plugin hooks in an event's chain: after the AI hook center's built-in hooks, at 100, and before the hook registry's, from 1,000.
    static let hookOrder = 200

    /// A started plugin, its context, and its activation, which its commands, panels, and page script values wait for.
    private struct RunningPlugin {
        let plugin: any Plugin
        let context: ScopedPluginContext
        let activation: Task<Void, any Error>
        /// Whether the activation succeeded, after which uses reach the plugin without waiting.
        var isActive = false
    }

    /// Changes to one setting that have not settled yet.
    private struct PendingSettingChange {
        /// The setting's value before the first of them, or nil for a secret setting.
        let before: PluginValue?
        /// Tells the plugin once they have settled; the next change cancels it.
        let delivery: Task<Void, Never>
    }

    /// The access that running one of a `whenInvoked` plugin's commands in a tab gives it: the tab's pages on the host of the document the command ran on, while the tab keeps the page it had then and the plugin the install, grant, and manifest it had then.
    private struct TabSiteAccess {
        /// `<scheme>://<host>/*` of the document the command ran on.
        let site: MatchPattern
        /// The tab's page at the command. A tab that gets another page, as when it unloads or changes engines, loses the access.
        weak var contents: (any EngineWebContents)?
        let grant: PluginGrant
        let manifest: PluginManifest
        /// When the plugin's package was installed, and where, which an update changes also when it keeps `plugin.json` and the page scripts, since it can change the rest of the code.
        let installedAt: Date?
        let packageURL: URL?
        /// The plugin's page scripts as the tab's documents on the site run them, with their own scripts (`accessScripts(of:grant:world:site:)`).
        let scripts: [(script: PluginPageScript, engineScript: EnginePageScript)]

        /// Whether the access belongs to the plugin as it is installed.
        func isFor(_ installed: InstalledPlugin) -> Bool {
            installed.grant == grant && installed.manifest == manifest && installed.installedAt == installedAt && installed.packageURL == packageURL
        }
    }

    /// `directory` is the app's Application Support folder. Built-in plugins get everything their manifests ask for. Of two built-in plugins with the same identifier, the first counts. The installed plugins follow, each read from its package, script plugins by the manager and other kinds by their `runtimes`; one whose package or `plugins.json` entry does not read, as one of a kind without a runtime, stays in the file but out of the list. A version whose identifier ends in an engine and that no record pairs, as a build before engine versions leaves it, is paired again with the other plugin of its package's identifier. The runtimes learn the enabled plugins of their kinds at once.
    /// `events` is the session's bus, whose events of the Persona reach the enabled plugins that list their kinds, `browserHost` reaches its tabs, and `ai` is the AI interface of the plugins with `ai`.
    public convenience init(persona: PersonaID, directory: URL, builtIns: [any BuiltInPlugin.Type], runtimes: [any PluginRuntime] = [],
                            events: BrowserEventBus? = nil, browserHost: (any PluginBrowserHost)? = nil, ai: AIService? = nil) {
        self.init(persona: persona, directory: directory, builtIns: builtIns, runtimes: runtimes, secretStore: PluginKeychain(), events: events, browserHost: browserHost, ai: ai)
    }

    init(persona: PersonaID, directory: URL, builtIns: [any BuiltInPlugin.Type], runtimes: [any PluginRuntime] = [], secretStore: any PluginSecretStore,
         scriptLimits: ScriptPluginLimits = .standard, publisherKeyDigest: Data = CRXArchive.webStorePublisherKeyDigest,
         events: BrowserEventBus? = nil, browserHost: (any PluginBrowserHost)? = nil, ai: AIService? = nil) {
        self.persona = persona
        self.browserHost = browserHost
        self.ai = ai
        self.directory = Self.folder(ofPersona: persona, in: directory)
        self.runtimes = Dictionary(runtimes.map { ($0.kind, $0) }) { first, _ in first }
        self.secretStore = secretStore
        self.scriptLimits = scriptLimits
        self.publisherKeyDigest = publisherKeyDigest
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
                  let package = try? PluginPackage(at: Self.packageFolder(of: id, in: self.directory), origin: install.origin, proof: install.proof, runtimes: runtimes),
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
        contributions = PluginContributionIndex(paired, disabledCommands: disabledCommands)
        // Packages that were under review when the app last quit cannot be installed any more.
        try? FileManager.default.removeItem(at: stagingDirectory)
        if !restored.isEmpty { saveList() }
        for runtime in self.runtimes.values {
            runtime.runtimeFile = Self.runtimeFile(of: runtime.kind, in: self.directory)
            runtime.onCheck = { [weak self] id, checks in self?.record(checks, for: id) }
            runtime.onEngineFailure = { [weak self] id, engine, reason in self?.recordEngineFailure(reason, of: id, on: engine) }
            runtime.onEnginesChange = { [weak self, kind = runtime.kind] in self?.readEngineChecks(of: kind) }
        }
        runEnabledPlugins()
        Self.liveManagers.add(self)
        registerAIFeatures()
        // The filter's empty tab kinds leave agent tabs out.
        self.events = events?.subscribe(BrowserEventFilter(scope: .places([.persona(persona)]))) { [weak self] event in self?.deliver(event) }
    }

    /// The installed package as the list shows it under its entry's identifier, with the entry's proof, with the part of the entry's grant that its manifest asks for, with why its runtime cannot run it, if it cannot, with the current answers of the engines that checked it, and with the engines whose note asking for a version the user dismissed.
    private static func installedPlugin(_ package: PluginPackage, id: PluginID, install: PluginListFile.Install, isEnabled: Bool, runtime: (any PluginRuntime)?) -> InstalledPlugin {
        InstalledPlugin(kind: package.kind, manifest: package.manifest, origin: package.origin, proof: install.proof, predatesProof: install.predatesProof,
                        packageURL: package.rootURL, grant: install.grant.limited(to: package.manifest, kind: package.kind),
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

    /// Choices, pairs, dismissals, removals, and the engines' answers are few and rare, so each writes the file at once. A write that fails, as on a full disk, keeps the change for the run and says why in `listWriteFailure`, since Settings and the runtimes make these changes without waiting for an answer.
    private func saveList() {
        do {
            try writeList()
        } catch {
            listWriteFailure = "Arch could not save the plugin list, so changes to it since then last only until Arch quits. \(error.localizedDescription)"
        }
    }

    /// Writes `plugins.json` from the lists, with the changes of earlier writes that failed, and clears `listWriteFailure`. Throws the encoder's or the file system's error, and the file then stays as it was.
    private func writeList() throws {
        let data = try JSONEncoder().encode(PluginListFile(choices: choices, installed: installs, engineVersions: pairRecords.isEmpty ? nil : pairRecords))
        try PluginFile.write(data, to: directory.appendingPathComponent(PluginListFile.name))
        if listWriteFailure != nil { listWriteFailure = nil }
    }

    /// Writes `plugins.json` again after a write failed, for Settings' Try Again; nothing once the manager is closed.
    public func writeListAgain() {
        guard !isClosed else { return }
        saveList()
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

    /// `Staging/` in the Persona's folder, where packages wait for review and the Web Store's downloads wait for staging. The manager clears it at launch.
    public var stagingDirectory: URL {
        directory.appendingPathComponent("Staging", isDirectory: true)
    }

    /// Copies a folder, `.zip` archive, or `.crx` file the user chose into the staging folder and reads its package there for the install sheet, without running any of it: a script plugin's, or one of a kind that a runtime reads. A `.crx` file's signatures must hold and give the package its proof (`CRXArchive`). The engines that run the kind on this Mac check the package, and the installed plugins it could update or join as a version, in the engines that have no current answer for them; the package then names what the review offers (see `PluginPackage`). Throws `PluginError.invalidPackage` or `.unsupportedAPIVersion` for a package Arch cannot install, for one whose identifier `checkInstallable(_:of:)` refuses, and, with the first engine's reason, for one that every engine refuses. A staged package ends with `install(_:grant:isEnabled:asVersionOf:for:)` or `discard(_:)`.
    public func stage(_ url: URL) async throws -> PluginPackage {
        let (runtimes, digest) = (Array(runtimes.values), publisherKeyDigest)
        return try await stage { root in try PluginPackage.stage(url, at: root, runtimes: runtimes, publisherKeyDigest: digest) }
    }

    /// Stages a `.crx` file that Arch downloaded with its origin, `file` for the place it stands for or `webStore` for the Web Store, as `stage(_:)` stages a file the user chose. With the origin `webStore`, it refuses a package without the store's proof, one whose identifier differs from the origin's, and a theme. The downloaded file stays where it is, for the caller to delete. Throws `PluginError.invalidPackage` for another origin, which no download has.
    public func stage(_ file: URL, origin: PluginOrigin) async throws -> PluginPackage {
        switch origin {
        case .file, .webStore: break
        case .bundled, .generated: throw PluginError.invalidPackage("Only a file or a Web Store package installs from a download.")
        }
        let (runtimes, digest) = (Array(runtimes.values), publisherKeyDigest)
        return try await stage { root in try PluginPackage.stage(file, at: root, origin: origin, runtimes: runtimes, publisherKeyDigest: digest) }
    }

    /// Writes the files of a plugin that AI wrote, `plugin.json` among them, at their package paths in the staging folder and reads its package there, as `stage(_:)` does for a folder.
    public func stage(_ files: [String: String], writtenBy composition: PluginComposition) async throws -> PluginPackage {
        try await stage { root in try PluginPackage.stage(files, at: root, origin: .generated(composition)) }
    }

    /// The package that `make` puts in a new folder of the staging folder, off the main thread, kept only while `checkInstallable(_:of:)` accepts its identifier and, for a kind that engines check, while an engine runs it. Throws `PluginError.closed` once the manager is closed.
    private func stage(_ make: @escaping @Sendable (URL) throws -> PluginPackage) async throws -> PluginPackage {
        guard !isClosed else { throw PluginError.closed }
        let root = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var package = try await Task.detached { try make(root) }.value
        do {
            try checkInstallable(package.manifest.id, of: package.kind)
            if package.kind == .webExtension, package.manifest.permissions.contains(.nativeMessaging) { await nativeAppGate?.update() }
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
        guard proofRefusal(joining: package.manifest, proof: package.proof, with: match) == nil else { return }
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

    /// Throws `PluginError.invalidPackage` for an identifier that no installed plugin of `kind` may have: a built-in plugin's, one under `archIdentifierPrefix` but outside `PluginComposer.identifierPrefix`, which a later build's built-in plugin could take, one of earlier builds that `PluginIdentifierMigration` renames at launch, an installed plugin's of another kind, which an update cannot turn into this kind, the install entry's identifier of a version that joined under its counterpart's identifier, such as `extension.<identifier>.chromium`, which an install would otherwise replace although its package names another identifier, or the name of `plugins.json`, of the copy kept of it when it does not decode, or of a runtime's file, such as `webExtension.json`, which the plugin's folder would take in the Persona's folder, whose names macOS compares without case.
    private func checkInstallable(_ id: PluginID, of kind: PluginKind) throws {
        guard builtIns[id] == nil else { throw PluginError.invalidPackage("A plugin built into Arch has the identifier \(id.rawValue).") }
        if id.rawValue.hasPrefix(Self.archIdentifierPrefix), !id.rawValue.hasPrefix(PluginComposer.identifierPrefix) {
            throw PluginError.invalidPackage("Arch keeps identifiers that start with \(Self.archIdentifierPrefix) for the plugins built into it, so no plugin can have \(id.rawValue) as its identifier.")
        }
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
        let files = [list, PluginFile.unreadableURL(of: list)] + runtimes.keys.map { Self.runtimeFile(of: $0, in: directory) }
        guard !files.contains(where: { $0.lastPathComponent.lowercased() == id.rawValue }) else {
            throw PluginError.invalidPackage("Arch keeps a file named \(id.rawValue) beside the installed plugins, so no plugin can have it as its identifier.")
        }
    }

    /// Deletes a staged package that the user chose not to install.
    public func discard(_ package: PluginPackage) {
        guard package.rootURL.deletingLastPathComponent().standardizedFileURL == stagingDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: package.rootURL)
    }

    /// Installs a staged package in the Persona with the part of `grant` that its manifest asks for, enabled or not as `isEnabled` says, and returns the plugin's identifier. With `asVersionOf` and `engine`, the package joins that plugin as its version for the engine, on or off as the plugin is. Otherwise a package with an installed plugin's identifier updates `package.updates`, or the first plugin with the identifier: the new package replaces the old one, the plugin keeps its place, storage, secrets, pair, and dismissed notes, and its running instance stops, so that its next use starts the new code. A new plugin that could have joined its counterpart as a version has, as has the counterpart, the note asking for a version dismissed for the engines the other runs on. A new plugin takes nothing from an install entry or a pair record with its identifier that the list leaves out, as a removal whose write failed leaves them: its entry goes after the others without the old dismissed notes, and the records go, so that it joins a pair only as the user chooses. Throws `PluginError.invalidPackage` for a version that cannot join (see `versionJoin(_:joining:for:)`) and for an update that would leave a version of a pair on no engine (`updateRefusal(for:updating:)`), `PluginError.closed` once the manager is closed, as for a review whose Persona the user deleted while it asked for Touch ID, and the file system's error when the package cannot move or `plugins.json` cannot record the install, as on a full disk. In the last case the staged package goes back to staging, the package it replaced back to its place, and the lists back to how they were, so that the review can install it again or discard it.
    @discardableResult
    public func install(_ package: PluginPackage, grant: PluginGrant, isEnabled: Bool, asVersionOf version: PluginID? = nil, for engine: EngineKind? = nil) throws -> PluginID {
        guard !isClosed else { throw PluginError.closed }
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
        let listed = (choices, installs, pairRecords)
        badges[id] = nil
        stop(id)
        let move = try PackageMove(from: package.rootURL, to: Self.packageFolder(of: id, in: directory))
        let installed = package.moved(to: move.installedURL)
        let runtime = runtimes[installed.kind]
        let checks = Self.fileChecks(package.engineChecks, engines: runtime?.engines ?? [:])
        var install = PluginListFile.Install(id: id.rawValue, origin: package.origin, proof: package.proof, grant: grant.limited(to: package.manifest, kind: package.kind), installedAt: Date(),
                                             engineChecks: checks.isEmpty ? nil : checks)
        if !isNew, let index = installs.firstIndex(where: { $0.id == install.id }) {
            if case let .readable(old) = installs[index] { install.dismissedVersionNotes = old.dismissedVersionNotes }
            installs[index] = .readable(install)
        } else {
            // An entry that the list leaves out, as one that a removal whose write failed leaves, gives a new plugin neither its place nor its dismissed notes.
            installs.removeAll { $0.id == install.id }
            installs.append(.readable(install))
        }
        recordChoice(isEnabled, for: id)
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
        } else if isNew {
            // A record that names the identifier, as one that a removal whose write failed leaves, would pair the new plugin without the user's choice.
            dropRecords(naming: [id])
            if !package.joinableEngines.isEmpty, let counterpart = package.counterpart, let match = next.first(where: { $0.id == counterpart }) {
                // The user chose to keep the two apart.
                dismiss(match.enginesRunningPackage, notesOf: id, in: &next)
                dismiss(plugin.enginesRunningPackage, notesOf: counterpart, in: &next)
            }
        }
        do {
            try writeList()
        } catch {
            // Without the entry, the next launch would not list a new plugin and would read an update's package with the old entry's grant and origin.
            move.undo()
            (choices, installs, pairRecords) = listed
            throw error
        }
        move.finish()
        packages[id] = installed
        failures[id] = nil
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
        if let refusal = proofRefusal(joining: package.manifest, proof: package.proof, with: plugin) { throw PluginError.invalidPackage(refusal) }
        let manifestID = package.manifest.id
        guard !plugins.contains(where: { $0.id != plugin.id && $0.manifest.id == manifestID }) else {
            throw PluginError.invalidPackage("Another installed plugin has this package\u{2019}s identifier, so it cannot join \u{201C}\(plugin.manifest.name)\u{201D} here. Join With\u{2026} joins installed plugins.")
        }
        let candidates = plugin.manifest.id == manifestID ? [manifestID.version(for: engine), manifestID] : [manifestID]
        guard let entryID = candidates.compactMap({ $0 }).first(where: { candidate in !plugins.contains { $0.id == candidate } }) else {
            throw PluginError.invalidPackage("An installed plugin has the identifier this version would take.")
        }
        return (entryID, PluginEngineVersions([engine: entryID, other: plugin.id]), plugin.isEnabled)
    }

    /// Why the version with `manifest` and `proof`, a package or a plugin, cannot join `plugin` as its counterpart while one of the two has proof of its identifier and the other has none under an identifier that the native app gate covers, so that a proven plugin does not appear to vouch for an unproven package; nil otherwise.
    private func proofRefusal(joining manifest: PluginManifest, proof: PluginProof?, with plugin: InstalledPlugin) -> String? {
        guard let nativeAppGate, (proof == nil) != (plugin.proof == nil) else { return nil }
        let unproven = proof == nil ? manifest : plugin.manifest
        guard nativeAppGate.refusal(of: unproven, proof: nil, predatesProof: false) != nil else { return nil }
        return "Arch can prove the identifier of only one of the two, and a native app on this Mac accepts the other\u{2019}s, so they cannot be one plugin."
    }

    /// The review's lines on where the package runs (`PluginPackage.engineNotes`), with the native app gate's sentence as its Chromium line when the gate would keep a package that Chromium runs out of it.
    public func engineNotes(of package: PluginPackage) -> [String] {
        guard package.kind == .webExtension, package.manifest.permissions.contains(.nativeMessaging), package.engineChecks[.chromium] == .runs,
              let refusal = nativeAppGate?.refusal(of: package.manifest, proof: package.proof, predatesProof: false) else { return package.engineNotes }
        var gated = package
        gated.engineChecks[.chromium] = .refused(refusal)
        return gated.engineNotes
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
        return "\(name), which you installed from \(source.lastPathComponent), has this package\u{2019}s identifier, so as its \(engine.displayName) version the package takes over the data that \(name) keeps on \(engine.displayName) tabs. Join only if both come from the same developer."
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
        if members.count == 2, let refusal = proofRefusal(joining: members[0].manifest, proof: members[0].proof, with: members[1]) {
            throw PluginError.invalidVersions(refusal)
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

    /// Deletes an installed plugin, or one version of a pair, from the Persona: it stops, and its package, storage, and secrets go, and its runtime deletes what it keeps of it. The other version of a pair stays installed in the pair's place with its grant, storage, and switch, and the pair's record goes. Built-in plugins cannot be removed, only switched off. Throws when the Keychain or the file system refuses, with the plugin still installed. A write of `plugins.json` that fails does not throw but sets `listWriteFailure`: the file keeps the plugin's entry, which the next launch leaves out of the list, since its package is gone, and its pair's record, which the next launch ignores, and an install with the identifier takes neither.
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

    /// Stops the plugins for good as the session deletes the Persona: they leave the list, so their contributions go and nothing starts them again, their running instances stop, and the storage changes that have not reached the files are dropped, since the Persona's folder goes at the next launch. From then on the manager stages, installs, and stores nothing.
    public func close() {
        isClosed = true
        events?.cancel()
        events = nil
        for id in Array(running.keys) { stop(id) }
        siteAccess = [:]
        tabPageScripts = [:]
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

    /// `<kind>.json` in the Persona's folder `directory`, the runtime's own file (`PluginRuntime.runtimeFile`).
    private static func runtimeFile(of kind: PluginKind, in directory: URL) -> URL {
        directory.appendingPathComponent("\(kind.rawValue).json")
    }

    // MARK: Contributions

    /// Runs a command that an enabled plugin contributes, its own or, in a pair, one of its enabled other version's that its own lacks (`InstalledPlugin.commands(among:)`), starting the plugin first if it has not started. A plugin that reaches its sites `whenInvoked` first gets access in the invocation's tab (`grantSiteAccess(to:for:)`), and a command that the access cannot be given for does not run. The plugin receives the invocation as `shown(_:to:of:)` gives it. A command that fails, that does not run for its access, or whose plugin fails to start, beeps.
    public func run(_ command: PluginCommandRef, _ invocation: PluginInvocation) async {
        guard let installed = enabledPlugin(command.plugin), !disabledCommands[command.plugin, default: []].contains(command.command), installed.commands(among: plugins).contains(where: { $0.id == command.command }) else { return }
        guard grantSiteAccess(to: installed, for: invocation) else { return NSSound.beep() }
        do {
            guard let plugin = try await start(installed), let context = running[installed.id]?.context else { return }
            context.userCommandCount += 1
            defer { context.userCommandCount -= 1 }
            try await plugin.run(command.command, shown(invocation, to: installed.grant, of: installed.id))
        } catch {
            NSSound.beep()
        }
    }

    /// The invocation as a plugin with the grant sees it: its tab as `shown(_:to:of:)` gives it, and for a plugin with `ai`, none of what the user clicked on when the tab's page is on a site excluded from AI, and no link or image address on such a site, which its code could send to a model as text.
    private func shown(_ invocation: PluginInvocation, to grant: PluginGrant, of plugin: PluginID) -> PluginInvocation {
        var shown = invocation
        shown.tab = invocation.tab.map { self.shown($0, to: grant, of: plugin) }
        if let tab = invocation.tab, excludesAI(tab, for: grant) {
            shown.linkURL = nil
            shown.imageURL = nil
            shown.selection = nil
        }
        if excludesAI(shown.linkURL, for: grant) { shown.linkURL = nil }
        if excludesAI(shown.imageURL, for: grant) { shown.imageURL = nil }
        return shown
    }

    /// The tab as the plugin with the grant sees it: without the title and addresses of a page it does not reach (`reaches(_:in:of:grant:)`) unless the grant has `tabs`, and for a plugin with `ai` without those of a page on a site excluded from AI, which its code could send to a model as text (hook decision 14).
    fileprivate func shown(_ tab: PluginTab, to grant: PluginGrant, of plugin: PluginID) -> PluginTab {
        var shown = tab.redacted(for: grant) { self.reaches($0, in: tab, of: plugin, grant: grant) }
        if excludesAI(tab, for: grant) {
            shown.title = nil
            shown.url = nil
            shown.documentURL = nil
        }
        return shown
    }

    /// Whether a plugin with the grant reaches AI and the tab's address or its document's is on a site excluded from AI.
    fileprivate func excludesAI(_ tab: PluginTab, for grant: PluginGrant) -> Bool {
        excludesAI(tab.url, for: grant) || excludesAI(tab.documentURL, for: grant)
    }

    /// Whether a plugin with the grant reaches AI and the address is on a site excluded from AI.
    private func excludesAI(_ url: URL?, for grant: PluginGrant) -> Bool {
        guard grant.permissions.contains(.ai), let ai, let url else { return false }
        return !ai.settings.allowsAI(on: url)
    }

    /// The panel of a sidebar item whose action is `.panel`, from its plugin, which starts first if it has not started. Nil, with a beep, when the plugin offers no panel for the item or fails to start.
    public func panel(for item: Attributed<PluginSidebarItem>) async -> NSViewController? {
        guard case .panel = item.item.action, let installed = enabledPlugin(item.plugin), installed.manifest.contributions.sidebarItems.contains(item.item) else { return nil }
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

    fileprivate func setEnabled(_ isEnabled: Bool, command id: String, of plugin: PluginID) {
        guard let installed = enabledPlugin(plugin), installed.commands(among: plugins).contains(where: { $0.id == id }) else { return }
        if isEnabled { disabledCommands[plugin, default: []].remove(id) }
        else { disabledCommands[plugin, default: []].insert(id) }
        contributions = PluginContributionIndex(plugins, disabledCommands: disabledCommands)
    }

    fileprivate func showPanel(_ item: String, of plugin: PluginID) {
        guard let installed = enabledPlugin(plugin), installed.manifest.contributions.sidebarItems.contains(where: {
            guard $0.id == item, case .panel = $0.action else { return false }
            return true
        }) else { return }
        panelRequest = (plugin, item, UUID())
    }

    // MARK: Page scripts

    /// Whether a page script of the enabled plugin runs in the main frame at `url` in every tab: the script's patterns and one of the plugin's granted sites cover the address, and the plugin reaches its sites as listed rather than `whenInvoked`, where its scripts run only in a tab after one of its commands.
    public func pageScriptsCover(_ url: URL, of id: PluginID) -> Bool {
        guard let installed = enabledPlugin(id), installed.grant.siteAccess == .listedSites, installed.grant.covers(url) else { return false }
        return installed.manifest.contributions.pageScripts.contains { $0.covers(url) }
    }

    /// Passes a value that a page script in `tab` sent to its plugin, starting the plugin first if it has not started. The value reaches the plugin only while the plugin is enabled and reaches the sending frame's document in the tab (`reaches(_:in:of:grant:)`), and the plugin receives the tab without what its grant does not cover. A plugin with `ai` could send what a page script read to a model as text, so it gets nothing from a frame or a tab on a site excluded from AI. Returns the plugin's reply as JSON text, or nil when there is none or the plugin fails.
    public func receive(_ message: EnginePageScriptMessage, from tab: PluginTab) async -> String? {
        guard let installed = plugins.first(where: { $0.id.pageScriptWorld == message.world }), installed.isEnabled,
              let frameURL = message.frameURL, reaches(frameURL, in: tab, of: installed.id, grant: installed.grant),
              !excludesAI(frameURL, for: installed.grant), !excludesAI(tab, for: installed.grant),
              let body = try? JSONDecoder().decode(PluginValue.self, from: Data(message.json.utf8)) else { return nil }
        let page = PluginPageMessage(tab: tab.redacted(for: installed.grant) { self.reaches($0, in: tab, of: installed.id, grant: installed.grant) },
                                     frameURL: frameURL, isMainFrame: message.isMainFrame, body: body)
        do {
            guard let reply = try await start(installed)?.receive(page) else { return nil }
            return String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        } catch {
            return nil
        }
    }

    // MARK: Site access

    /// The page scripts that a tab's pages run: the Persona's, which every tab runs, then those of the plugins that have access in the tab after one of their commands ran there (`accessPageScripts(forTab:)`).
    public func pageScripts(forTab id: UUID) -> [EnginePageScript] {
        contributions.pageScripts + accessPageScripts(forTab: id)
    }

    /// The page scripts of the plugins whose access in the tab still holds, in the order of the list, which the session gives the tab after the Persona's. An access that no longer holds gives none, although `tabPageScripts` keeps it until its next check ends it: so a web contents that a tab gets after unloading or a change of engine, which ends its access, never takes the scripts of that access from a later change to another tab's.
    public func accessPageScripts(forTab id: UUID) -> [EnginePageScript] {
        // Most tabs have no access, and the session asks for each tab of the Persona when the Persona's scripts change, so the tabs are read only for one with access.
        guard siteAccess.values.contains(where: { $0[id] != nil }), let tab = personaTabs().first(where: { $0.id == id }) else { return [] }
        return plugins.flatMap { plugin in siteAccess[plugin.id]?[id].flatMap { holds($0, of: plugin.id, in: tab) ? $0.scripts.map(\.engineScript) : nil } ?? [] }
    }

    /// Gives a plugin that reaches its sites `whenInvoked` access in the invocation's tab when the user ran the command on a document of one of the Persona's tabs that the granted sites cover: the tab's pages on the host of that document, which run the plugin's page scripts from then on (`tabPageScripts`). The scripts that cover the document also run in it at once, without the user's gesture as a page run, which on WebKit needs the flags for plugins' page runs and otherwise leaves them to the tab's next document on the host. A later command in the tab keeps the access as it is and runs them at once again, so that a document that did not run them, as one that began while the flags switched page runs off, runs them then; each runs once in a document (`accessScripts(of:grant:world:site:)`).
    /// Returns false, and the command does not run, when the access cannot be for the document the user ran the command on: the tab shows another document by now, as one that the page or one of its scripts loaded while its context menu was open, the granted sites no longer cover it, or no match pattern can name its host, as for an IPv6 address.
    private func grantSiteAccess(to installed: InstalledPlugin, for invocation: PluginInvocation) -> Bool {
        guard installed.grant.siteAccess == .whenInvoked, let shown = invocation.tab, let tab = personaTabs().first(where: { $0.id == shown.id }),
              let shownDocument = shown.documentURL, installed.grant.covers(shownDocument) else { return true }
        guard let documentID = tab.documentID, documentID == shown.documentID, let document = tab.documentURL, document.host() == shownDocument.host(),
              installed.grant.covers(document), let contents = browserHost?.webContents(forTab: tab.id) else { return false }
        let access: TabSiteAccess
        if let current = currentSiteAccess(of: installed.id, in: tab) {
            access = current
        } else {
            guard let scheme = document.scheme, let host = document.host(), let site = try? MatchPattern("\(scheme)://\(host)/*") else { return false }
            access = TabSiteAccess(site: site, contents: contents, grant: installed.grant, manifest: installed.manifest, installedAt: installed.installedAt,
                                   packageURL: installed.packageURL,
                                   scripts: Self.accessScripts(of: installed.manifest, grant: installed.grant, world: installed.id.pageScriptWorld, site: site))
            siteAccess[installed.id, default: [:]][tab.id] = access
            publishTabPageScripts()
        }
        for (script, engineScript) in access.scripts where script.covers(document) {
            contents.executeJavaScriptWithoutUserGesture(engineScript.source, inWorld: engineScript.world) { _ in }
        }
        return true
    }

    /// The plugin's page scripts as a tab with its access on `site` runs them, with their own scripts: each checks the site besides its patterns and the granted sites, and runs once in a document under its world and its place in the manifest.
    private static func accessScripts(of manifest: PluginManifest, grant: PluginGrant, world: String, site: MatchPattern) -> [(script: PluginPageScript, engineScript: EnginePageScript)] {
        manifest.contributions.pageScripts.enumerated().compactMap { index, script in
            script.engineScript(world: world, sites: grant.sites, within: [site], once: "\(world)#\(index)").map { (script, $0) }
        }
    }

    /// Whether the plugin with the grant reaches the page at `url` in `tab`, a tab of the Persona as the browser host gives it: the granted sites cover the page, and for `whenInvoked` the plugin's access in the tab covers it too. Without a tab, a `whenInvoked` plugin reaches no page.
    fileprivate func reaches(_ url: URL, in tab: PluginTab?, of plugin: PluginID, grant: PluginGrant) -> Bool {
        guard grant.covers(url) else { return false }
        guard grant.siteAccess == .whenInvoked else { return true }
        guard let tab, let access = currentSiteAccess(of: plugin, in: tab) else { return false }
        return access.site.matches(url)
    }

    /// The host of the plugin's access in the tab, for a page run's check in the page, or none without access, which covers no page.
    fileprivate func accessSites(of plugin: PluginID, inTab id: UUID) -> [MatchPattern] {
        guard let tab = personaTabs().first(where: { $0.id == id }), let access = currentSiteAccess(of: plugin, in: tab) else { return [] }
        return [access.site]
    }

    /// The plugin's access in `tab`, a tab of the Persona as the browser host gives it, while it holds (`holds(_:of:in:)`). Access that no longer holds ends.
    private func currentSiteAccess(of plugin: PluginID, in tab: PluginTab) -> TabSiteAccess? {
        guard let access = siteAccess[plugin]?[tab.id] else { return nil }
        if holds(access, of: plugin, in: tab) { return access }
        endSiteAccess(of: [plugin], inTab: tab.id)
        return nil
    }

    /// Whether the access holds in `tab`: the tab keeps the page it had at the command and shows a document on the access's host, and the plugin is enabled as it was installed then, with the grant and manifest it had then.
    private func holds(_ access: TabSiteAccess, of plugin: PluginID, in tab: PluginTab) -> Bool {
        guard let installed = enabledPlugin(plugin), access.isFor(installed), let contents = access.contents, contents === browserHost?.webContents(forTab: tab.id),
              let document = tab.documentURL else { return false }
        return access.site.matches(document)
    }

    /// Ends the access that a tab loses with the event: all of it when the tab closes or leaves the Persona's tabs, and otherwise what no longer holds, as once the tab commits a document of another host (`eventTab(_:)`).
    private func endSiteAccess(after event: BrowserEvent) {
        guard let id = event.tab?.id else { return }
        let holders = siteAccess.filter { $0.value[id] != nil }.map(\.key)
        guard !holders.isEmpty else { return }
        guard event.kind != .tabClosed, let tab = eventTab(event) else { return endSiteAccess(of: holders, inTab: id) }
        for plugin in holders { _ = currentSiteAccess(of: plugin, in: tab) }
    }

    /// The event's tab as the browser host gives it, showing the document the event is about: the tab posts `addressChanged` before it takes the new committed address, which the event carries.
    private func eventTab(_ event: BrowserEvent) -> PluginTab? {
        guard let ref = event.tab, var tab = personaTabs().first(where: { $0.id == ref.id }) else { return nil }
        if event.kind == .addressChanged { tab.documentURL = ref.url }
        return tab
    }

    private func endSiteAccess(of plugins: [PluginID], inTab id: UUID) {
        for plugin in plugins { siteAccess[plugin]?[id] = nil }
        siteAccess = siteAccess.filter { !$0.value.isEmpty }
        publishTabPageScripts()
    }

    /// Ends the access of the plugins that are no longer enabled, or no longer as they were installed at the command, as after an update, also one that keeps `plugin.json`, after a change to the list.
    private func pruneSiteAccess() {
        var pruned: [PluginID: [UUID: TabSiteAccess]] = [:]
        for (plugin, tabs) in siteAccess {
            guard let installed = enabledPlugin(plugin) else { continue }
            let kept = tabs.filter { $0.value.isFor(installed) }
            if !kept.isEmpty { pruned[plugin] = kept }
        }
        guard pruned.values.map(\.count).reduce(0, +) != siteAccess.values.map(\.count).reduce(0, +) else { return }
        siteAccess = pruned
        publishTabPageScripts()
    }

    /// Sets `tabPageScripts` from each tab's access, in the order of the plugins in the list.
    private func publishTabPageScripts() {
        var scripts: [UUID: [EnginePageScript]] = [:]
        for plugin in plugins {
            for (tab, access) in siteAccess[plugin.id] ?? [:] {
                scripts[tab, default: []] += access.scripts.map(\.engineScript)
            }
        }
        if scripts != tabPageScripts { tabPageScripts = scripts }
    }

    // MARK: Events

    /// Hands a browser event of the Persona to each enabled plugin whose manifest lists its kind, starting the plugin first if it has not started, in the view its grant allows: addresses with `tabs` or on the pages its granted sites cover, and a download's identifiers only. A plugin never receives the events its own calls caused, such as the title change of its rename, and receives at most 10 events for one subject and 60 in all within a minute, so a listener that reacts to another plugin's or a hook's changes cannot keep them going without end. What a plugin's listener throws goes nowhere; a background script that hangs counts as a failure, as for commands.
    /// A plugin with `ai` receives its events through the shared hook scheduler instead (`hookStep(for:view:)`): one step for each, which joins the event's chain at `hookOrder`.
    private func deliver(_ event: BrowserEvent) {
        guard !isClosed else { return }
        endSiteAccess(after: event)
        var steps: [AIHookStep] = []
        for installed in plugins where installed.isEnabled && installed.unavailability == nil && installed.manifest.events.contains(event.kind) {
            if event.cause?.origin == .plugin(id: installed.id.rawValue) { continue }
            let grant = installed.grant
            // Only a plugin that reaches its sites `whenInvoked` needs the tab, whose access its addresses need.
            let tab = grant.siteAccess == .whenInvoked ? eventTab(event) : nil
            guard let view = event.view(.plugin(tabs: grant.permissions.contains(.tabs), downloads: false, covers: { self.reaches($0, in: tab, of: installed.id, grant: grant) })),
                  eventLimiter.admit(installed.id.rawValue, subject: event.subject, at: Date()) == .allowed else { continue }
            if installed.runsHooks, ai != nil {
                steps.append(hookStep(for: installed.id, view: view, tab: event.tab?.id, document: Self.document(of: event)))
            } else {
                Task { try? await start(installed)?.handle(.browser(view)) }
            }
        }
        guard let ai, !steps.isEmpty else { return }
        ai.hooks.scheduler.post(steps, kind: event.kind.rawValue, subject: event.subject, event: event.id, document: Self.document(of: event),
                                documentID: event.tab?.documentID, urls: event.urls, causes: Self.owners(causing: event))
    }

    /// The step that runs the plugin's listeners for one event under the plugin's feature, so that the scheduler applies the feature's checks: it is on and automatic, has a model of its own, the event's addresses are not excluded from AI, and the daily limit for automatic requests and the monthly spending limit leave room. It runs while the plugin is still enabled with `ai`, after the plugin's earlier steps, within the scheduler's 30-second timeout; what the listener throws goes nowhere. `tab` and `document` are the event's tab and, for a page, address, or title event, its address, to which the step's renames of that tab apply.
    private func hookStep(for id: PluginID, view: BrowserEventScriptView, tab: UUID?, document: URL?) -> AIHookStep {
        let feature = AIFeatureID.plugin(id.rawValue)
        return AIHookStep(owner: feature.rawValue, order: Self.hookOrder, feature: feature, routes: [feature.rawValue],
                          mayRun: { [weak self] in self?.enabledPlugin(id)?.runsHooks == true },
                          run: { [weak self] requestDidEnd in try await self?.runHook(of: id, view, tab: tab, document: document, requestDidEnd: requestDidEnd) })
    }

    /// Starts the plugin if needed and hands it the event once its earlier steps have ended, unless the scheduler stopped the step meanwhile. The AI requests the plugin asks for while its listener runs belong to the step, whichever of its listeners asks, since its calls do not say: their errors count toward the scheduler's pause, and when the scheduler stops the step, as at the tab's next document or close, or a change to the plugin's route, they end with `cancelled`, later ones end at once, and the step renames nothing more. The listener holds the plugin's later steps until it returns.
    private func runHook(of id: PluginID, _ view: BrowserEventScriptView, tab: UUID?, document: URL?,
                         requestDidEnd: @escaping @MainActor @Sendable ((any Error)?) -> Void) async throws {
        let queue = hookQueues[id] ?? PluginHookQueue()
        hookQueues[id] = queue
        try await queue.run {
            guard !Task.isCancelled, let installed = enabledPlugin(id), installed.runsHooks,
                  let plugin = try await start(installed), let context = running[id]?.context, running[id]?.plugin === plugin,
                  // The scheduler may have stopped the step while the plugin started.
                  !Task.isCancelled else { return }
            let step = PluginHookStep(tab: tab, document: document, requestDidEnd: requestDidEnd)
            context.hookStep = step
            defer { if context.hookStep === step { context.hookStep = nil } }
            try await withTaskCancellationHandler {
                try await plugin.handle(.browser(view))
            } onCancel: {
                Task { @MainActor in context.stop(step) }
            }
        }
    }

    /// The address of a page, address, or title event, whose chain ends when the tab commits another document.
    private static func document(of event: BrowserEvent) -> URL? {
        switch event.payload {
        case .pageLoaded(let tab, _, _), .addressChanged(let tab, _), .titleChanged(let tab, _): return tab.url
        default: return nil
        }
    }

    /// The scheduler's owners whose runs caused the event: the plugin whose call made the change, and the hooks in its cause's chain, named as the hook registry names them. The effect of a running step then joins that step's chain rather than stopping it.
    private static func owners(causing event: BrowserEvent) -> Set<String> {
        guard let cause = event.cause else { return [] }
        var owners = Set(cause.hookChain.map { "hook.\($0.uuidString)" })
        if case .plugin(let id) = cause.origin { owners.insert(AIFeatureID.plugin(id).rawValue) }
        return owners
    }

    // MARK: AI features

    /// Registers the feature of each enabled plugin with `ai` and unregisters those that no plugin has any more. The managers of several Personas can hold plugins with one identifier, which share the feature `plugin.<id>` and its route: it stays registered while one of them has it, is automatic while one of them runs hooks, and declares the data kinds that any of them lists, while each instance holds its requests to its own plugin's kinds (`PluginAIRequests`).
    private func registerAIFeatures() {
        guard let ai else { return }
        let enabled = isClosed ? [] : plugins.filter { $0.isEnabled && $0.unavailability == nil && $0.grant.permissions.contains(.ai) }
        let wanted = Dictionary(enabled.map { (AIFeatureID.plugin($0.id.rawValue), AIFeature.plugin($0)) }) { first, _ in first }
        let previous = aiFeatures
        aiFeatures = wanted
        // A feature's summary follows its trigger.
        let changed = Set(previous.keys).union(wanted.keys).filter {
            previous[$0]?.name != wanted[$0]?.name || previous[$0]?.trigger != wanted[$0]?.trigger || previous[$0]?.data.kinds != wanted[$0]?.data.kinds
        }
        let managers = Self.liveManagers.allObjects.filter { $0.ai === ai }
        for id in changed {
            let holders = managers.compactMap { $0.aiFeatures[id] }
            if var feature = holders.first(where: { $0.trigger == .automatic }) ?? holders.first {
                feature.data.kinds = holders.reduce(into: []) { $0.formUnion($1.data.kinds) }
                ai.register(feature)
            } else {
                ai.unregister(id)
            }
        }
    }

    // MARK: Settings

    /// The value of a plugin's setting: the user's, or the default for one the user has not changed or whose stored value no longer suits the field. Nil for a secret setting, whose value stays in the Keychain.
    public func value(of setting: PluginSetting, for id: PluginID) -> PluginValue? {
        guard let stored = storage(for: id).settingValue(forKey: setting.key), setting.kind.accepts(stored) else { return setting.kind.defaultValue }
        return stored
    }

    /// nil restores the default. Throws as `PluginStorage.setValue(_:forKey:)` does, since setting values share the plugin's storage, and `PluginError.closed` once the manager is closed. A plugin that asks for its setting changes hears of it (`settingDidChange(_:of:from:)`).
    public func setValue(_ value: PluginValue?, of setting: PluginSetting, for id: PluginID) throws {
        guard !isClosed else { throw PluginError.closed }
        objectWillChange.send()
        let before = self.value(of: setting, for: id)
        try storage(for: id).setSettingValue(value, forKey: setting.key)
        settingDidChange(setting, of: id, from: before)
    }

    /// Whether the Keychain holds a value for a secret setting. It reads only whether the item exists, so macOS does not ask for the keychain password.
    public func hasSecret(_ setting: PluginSetting, for id: PluginID) throws -> Bool {
        try secrets(for: id).containsSecret(forKey: setting.key)
    }

    /// nil deletes the Keychain item. Throws as `PluginSecrets.setSecret(_:forKey:)` does, and `PluginError.closed` once the manager is closed. A plugin that asks for its setting changes hears of it once the Keychain has the change.
    public func setSecret(_ secret: String?, of setting: PluginSetting, for id: PluginID) async throws {
        guard !isClosed else { throw PluginError.closed }
        try await secrets(for: id).setSecret(secret, forKey: setting.key)
        // Settings reads whether the item exists once the write is done.
        objectWillChange.send()
        settingDidChange(setting, of: id, from: nil)
    }

    /// The setting `key` of the plugin's manifest, as `PluginContext.setting(_:)` reads it.
    fileprivate func setting(_ key: String, of id: PluginID) -> PluginValue? {
        guard let setting = plugins.first(where: { $0.id == id })?.manifest.contributions.settings.first(where: { $0.key == key }) else { return nil }
        return value(of: setting, for: id)
    }

    /// How long a setting's changes settle before its plugin hears of them, so that a text field, which writes at each keystroke, tells the plugin once: as long as the plugin's storage changes settle before they reach the file.
    static let settingChangeDelay: Duration = .milliseconds(500)

    /// Tells the plugin, as `PluginEvent.settingChanged`, of a change the user made to one of its settings, once the setting's changes have settled for `settingChangeDelay`, while the plugin is enabled, its runtime can run it, and its manifest asks for its setting changes and still lists the setting, starting the plugin first if it has not started, as an event does. Nothing reaches it when the value is back where it was before the first of those changes; `before` is that value, or nil for a secret setting, whose value the manager does not read, so that each of its changes counts. The user makes every change, so loop protection's rate does not apply, and a plugin with `ai` hears of it outside the hook scheduler, as it runs a command.
    private func settingDidChange(_ setting: PluginSetting, of id: PluginID, from before: PluginValue?) {
        guard enabledPlugin(id)?.manifest.receivesSettingChanges == true else { return }
        let first = settingChanges[id]?[setting.key]?.before ?? before
        settingChanges[id]?[setting.key]?.delivery.cancel()
        let delivery = Task { [weak self] in
            try? await Task.sleep(for: Self.settingChangeDelay)
            guard let self, !Task.isCancelled else { return }
            settingChanges[id]?[setting.key] = nil
            guard !isClosed, let installed = enabledPlugin(id), installed.manifest.receivesSettingChanges,
                  installed.manifest.contributions.settings.contains(where: { $0.key == setting.key }),
                  first == nil || value(of: setting, for: id) != first else { return }
            try? await start(installed)?.handle(.settingChanged(key: setting.key))
        }
        settingChanges[id, default: [:]][setting.key] = PendingSettingChange(before: first, delivery: delivery)
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
                            storage: ScopedPluginStorage(file: storage(for: installed.id)), secrets: secrets(for: installed.id),
                            ai: installed.grant.permissions.contains(.ai) ? ai.map { PluginAIRequests(service: $0, feature: .plugin(installed.id.rawValue), dataKinds: installed.aiDataKinds) } : nil)
    }

    /// The Persona's tabs before the grant applies.
    fileprivate func personaTabs() -> [PluginTab] {
        browserHost?.tabs(in: persona) ?? []
    }

    fileprivate func personaDownloads() -> [PluginDownload] {
        browserHost?.downloads(in: persona) ?? []
    }

    fileprivate func notify(_ plugin: PluginID, title: String, body: String) {
        let now = Date()
        guard lastNotification[plugin].map({ now.timeIntervalSince($0) >= 10 }) ?? true,
              let name = plugins.first(where: { $0.id == plugin && $0.isEnabled })?.manifest.name else { return }
        lastNotification[plugin] = now
        browserHost?.postNotification(pluginName: name, title: title, body: body)
    }

    /// The tab of the Persona that a page call of the plugin with the grant names, before the grant applies, with its page. Throws `PluginError.notGranted` for a tab outside the Persona or an agent tab, `noPage` for a tab whose engine committed no document or that has no page, and `siteNotGranted`, which names no address, for a document the plugin does not reach (`reaches(_:in:of:grant:)`), as one outside the granted sites or, for `whenInvoked`, in a tab without the plugin's access, or for a plugin with `ai` a document or shown address on a site excluded from AI, which its code could send to a model as text.
    fileprivate func page(of id: UUID, for grant: PluginGrant, of plugin: PluginID) throws -> (tab: PluginTab, contents: any EngineWebContents) {
        guard let tab = personaTabs().first(where: { $0.id == id }) else { throw PluginError.notGranted(id) }
        guard let document = tab.documentURL else { throw PluginError.noPage }
        guard reaches(document, in: tab, of: plugin, grant: grant), !excludesAI(tab, for: grant) else { throw PluginError.siteNotGranted }
        guard let contents = browserHost?.webContents(forTab: id) else { throw PluginError.noPage }
        return (tab, contents)
    }

    /// How long a page call's run waits for the page's reply: the hang limit, 10 seconds by default, as long as Chromium's engine waits for one.
    fileprivate var pageRunLimit: Duration {
        .seconds(scriptLimits.hang)
    }

    /// Where the script that the plugin runs in a page comes from: script text from a built-in plugin, or a file of a script plugin's package, which `PluginPageRun.function(running:sites:)` reads off the main actor. Throws `PluginError.invalidPageScript` for anything else.
    fileprivate func source(of script: PluginScript, for id: PluginID) throws -> PluginPageRun.Source {
        switch script {
        case let .source(text):
            guard builtIns[id] != nil else { throw PluginError.invalidPageScript("Only plugins built into Arch run script text in pages.") }
            return .text(text)
        case let .file(path):
            guard let package = packages[id], package.kind == .script else {
                throw PluginError.invalidPageScript("\u{201C}\(path)\u{201D} is not a text file of the plugin\u{2019}s package.")
            }
            return .file(path, of: package)
        }
    }

    /// Renames a tab of the Persona for `document`, or for the document it shows now when that is nil, with the plugin as the cause of the change.
    fileprivate func renameTab(_ id: UUID, to name: String?, showing document: URL?, by plugin: PluginID) -> Bool {
        browserHost?.renameTab(id, to: name, showing: document, cause: Self.cause(plugin), applying: true) ?? false
    }

    /// The selected tab of the window that last became main, before the grant applies, while it is one of the Persona's tabs that `personaTabs()` lists.
    fileprivate func selectedTab() -> PluginTab? {
        guard let id = browserHost?.selectedTab(in: persona) else { return nil }
        return personaTabs().first { $0.id == id }
    }

    /// A plugin opens at most this many tabs within a minute. Each new tab is an event subject of its own, so the event rate's cap for one subject never stops plugins that open a tab for each other's `tabOpened`, and each tab costs a web content process.
    static let tabOpenLimit = 10

    /// Opens a tab of the Persona with the plugin as the cause of its events, unless the plugin has opened `tabOpenLimit` tabs within the last minute, which throws `PluginError.tooManyTabs`. Throws as the host does, and `PluginError.closed` without the host.
    fileprivate func openTab(_ url: URL, _ options: PluginOpenTabOptions, by plugin: PluginID) throws -> UUID {
        guard let browserHost else { throw PluginError.closed }
        let date = Date()
        let recent = (tabOpenings[plugin] ?? []).filter { date.timeIntervalSince($0) < BrowserEventRateLimiter.window }
        tabOpenings[plugin] = recent.isEmpty ? nil : recent
        guard recent.count < Self.tabOpenLimit else { throw PluginError.tooManyTabs }
        let id = try browserHost.openTab(url, options, in: persona, cause: Self.cause(plugin))
        tabOpenings[plugin] = recent + [date]
        return id
    }

    /// Closes or selects one of the Persona's tabs that `personaTabs()` lists, with the plugin as the cause of its events. Throws `PluginError.notGranted` for any other tab.
    fileprivate func closeTab(_ id: UUID, by plugin: PluginID) throws {
        guard personaTabs().contains(where: { $0.id == id }) else { throw PluginError.notGranted(id) }
        browserHost?.closeTab(id, cause: Self.cause(plugin))
    }

    fileprivate func selectTab(_ id: UUID, by plugin: PluginID) throws {
        guard personaTabs().contains(where: { $0.id == id }) else { throw PluginError.notGranted(id) }
        browserHost?.selectTab(id, cause: Self.cause(plugin))
    }

    /// Moves one of the Persona's tabs that `personaTabs()` lists, next to another of them or to a space, with the plugin as the cause of its events. Throws `PluginError.notGranted` for any other tab, as the one moved or the one to go next to, and as the host does.
    fileprivate func moveTab(_ id: UUID, to place: PluginTabPlace, by plugin: PluginID) throws -> Bool {
        let reached = Set(personaTabs().map(\.id))
        guard reached.contains(id) else { throw PluginError.notGranted(id) }
        if let neighbor = place.neighbor, !reached.contains(neighbor) { throw PluginError.notGranted(neighbor) }
        return try browserHost?.moveTab(id, to: place, cause: Self.cause(plugin)) ?? false
    }

    /// The cause of a change that the plugin's call makes, by which the plugin hears of none of the events it posts.
    private static func cause(_ plugin: PluginID) -> BrowserEventCause {
        BrowserEventCause(origin: .plugin(id: plugin.rawValue))
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

/// A staged package moved to `<plugin id>/package/`, which an install undoes when `plugins.json` cannot record it: the package it replaces stays beside it as `package.replaced` until the install finishes. Each step renames within the Persona's folder, so undoing it needs no free space.
private struct PackageMove {
    /// The name of the replaced package beside the new one. A later update replaces one that a crash left there.
    private static let replacedName = "package.replaced"
    private let stagedURL: URL
    private let destination: URL
    /// Where the package is now, which `replaceItemAt` may choose.
    let installedURL: URL
    /// The package that the move replaced, if any.
    private let replacedURL: URL?
    /// The plugin's folder, if the move created it.
    private let createdFolder: URL?

    init(from stagedURL: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        self.stagedURL = stagedURL
        self.destination = destination
        if fileManager.fileExists(atPath: destination.path) {
            installedURL = try fileManager.replaceItemAt(destination, withItemAt: stagedURL, backupItemName: Self.replacedName, options: .withoutDeletingBackupItem) ?? destination
            replacedURL = folder.appendingPathComponent(Self.replacedName, isDirectory: true)
            createdFolder = nil
        } else {
            let createdFolder = fileManager.fileExists(atPath: folder.path) ? nil : folder
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                try fileManager.moveItem(at: stagedURL, to: destination)
            } catch {
                if let createdFolder { try? fileManager.removeItem(at: createdFolder) }
                throw error
            }
            installedURL = destination
            replacedURL = nil
            self.createdFolder = createdFolder
        }
    }

    /// Deletes the replaced package once `plugins.json` records the install.
    func finish() {
        if let replacedURL { try? FileManager.default.removeItem(at: replacedURL) }
    }

    /// Moves the package back to staging, then the replaced package back to its place, and deletes the plugin's folder if the move created it. Once the package cannot leave, the rest stays as it is, so that no package is lost.
    func undo() {
        let fileManager = FileManager.default
        guard (try? fileManager.moveItem(at: installedURL, to: stagedURL)) != nil else { return }
        if let replacedURL { try? fileManager.moveItem(at: replacedURL, to: destination) }
        if let createdFolder { try? fileManager.removeItem(at: createdFolder) }
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

    /// An installed plugin, whose manifest its package in `<id>/package/` holds. The file names its origin with `source`, the folder or archive the user installed it from, with `generated`, how AI wrote it, or, for a package whose `.crx` signatures proved its identifier, with `proof` and either `signedSource`, the file, or `webStore`, the store's identifier. Builds before package proofs read only `source` and `generated`, so they keep a proven entry as one they cannot read instead of writing it again without its proof (`docs/web-store.md`, Package proof).
    struct Install: Codable {
        /// The plugin's identifier as `PluginID` writes it.
        var id: String
        /// A file, the Web Store, or AI, never the app: built-in plugins are not installed.
        var origin: PluginOrigin
        /// The entry's `proof` as the file holds it: a `PluginProof` value, or one this build does not know, which counts as none and stays in the file.
        var proofValue: String?
        /// Whether the entry names its file with `signedSource` rather than `source`.
        var namesSignedSource = false
        var grant: PluginGrant
        var installedAt: Date
        /// What each engine that checked the package found, by engine name as `EngineKind` writes it. Names stay text, so that the answers of engines this build does not know survive its writes. Absent from entries of builds before engine checks and of kinds that run alike on every engine.
        var engineChecks: [String: EngineCheck]?
        /// The engines whose note asking for a version of the plugin the user dismissed, by engine name, including names this build does not know. Absent where the user dismissed none.
        var dismissedVersionNotes: [String]?

        private enum CodingKeys: String, CodingKey {
            case id, source, signedSource, webStore, generated, proof, grant, installedAt, engineChecks, dismissedVersionNotes
        }

        /// A proven package's entry names its file with `signedSource`.
        init(id: String, origin: PluginOrigin, proof: PluginProof? = nil, grant: PluginGrant, installedAt: Date, engineChecks: [String: EngineCheck]?) {
            self.id = id
            self.origin = origin
            proofValue = proof?.rawValue
            namesSignedSource = proof != nil
            self.grant = grant
            self.installedAt = installedAt
            self.engineChecks = engineChecks
        }

        /// Whether the entry names a `.crx` file with `source`, as entries of builds before package proofs do.
        var predatesProof: Bool {
            guard case let .file(url) = origin, !namesSignedSource else { return false }
            return url.pathExtension.lowercased() == "crx"
        }

        /// What proves the package's identifier: the known `proof` of an entry with `signedSource` or `webStore`. An entry with `source` has none, whatever its `proof` says, as a `.crx` file installed before Arch checked signatures has.
        var proof: PluginProof? {
            switch origin {
            case .webStore: return proofValue.flatMap(PluginProof.init(rawValue:))
            case .file where namesSignedSource: return proofValue.flatMap(PluginProof.init(rawValue:))
            case .file, .generated, .bundled: return nil
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            if let composition = try container.decodeIfPresent(PluginComposition.self, forKey: .generated) {
                origin = .generated(composition)
            } else if let storeID = try container.decodeIfPresent(String.self, forKey: .webStore) {
                origin = .webStore(storeID)
            } else if let file = try container.decodeIfPresent(URL.self, forKey: .signedSource) {
                origin = .file(file)
                namesSignedSource = true
            } else {
                origin = .file(try container.decode(URL.self, forKey: .source))
            }
            proofValue = try container.decodeIfPresent(String.self, forKey: .proof)
            grant = try container.decode(PluginGrant.self, forKey: .grant)
            installedAt = try container.decode(Date.self, forKey: .installedAt)
            engineChecks = try container.decodeIfPresent([String: EngineCheck].self, forKey: .engineChecks)
            dismissedVersionNotes = try container.decodeIfPresent([String].self, forKey: .dismissedVersionNotes)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            switch origin {
            case let .file(url): try container.encode(url, forKey: namesSignedSource ? .signedSource : .source)
            case let .webStore(storeID): try container.encode(storeID, forKey: .webStore)
            case let .generated(composition): try container.encode(composition, forKey: .generated)
            // Nothing installs a built-in plugin.
            case .bundled: break
            }
            try container.encodeIfPresent(proofValue, forKey: .proof)
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
final class ScopedPluginContext: PluginPanelContext {
    var userCommandCount = 0
    let pluginID: PluginID
    let personaID: PersonaID
    let grant: PluginGrant
    private let scopedStorage: ScopedPluginStorage
    private let scopedSecrets: ScopedPluginSecrets
    private let aiRequests: PluginAIRequests?
    private weak var manager: PluginManager?
    private var hasEnded = false
    /// The page calls' runs that wait for the page's reply, by number, which `end()` ends.
    private var pageRuns: [Int: CheckedContinuation<String?, any Error>] = [:]
    private var nextPageRun = 0

    init(manager: PluginManager, pluginID: PluginID, personaID: PersonaID, grant: PluginGrant, storage: ScopedPluginStorage, secrets: ScopedPluginSecrets, ai: PluginAIRequests? = nil) {
        self.manager = manager
        self.pluginID = pluginID
        self.personaID = personaID
        self.grant = grant
        scopedStorage = storage
        scopedSecrets = secrets
        aiRequests = ai
    }

    var storage: any PluginStorage { scopedStorage }
    var secrets: any PluginSecrets { scopedSecrets }

    /// The hook step whose listener runs now, to which the AI requests asked for meanwhile and the renames of its tab belong.
    var hookStep: PluginHookStep? {
        get { aiRequests?.step }
        set { aiRequests?.step = newValue }
    }

    /// Stops the context, its storage, its secrets, and its AI requests from acting for the instance, and ends the waits of its page runs with `PluginError.stopped`.
    func end() {
        hasEnded = true
        scopedStorage.end()
        scopedSecrets.end()
        aiRequests?.end()
        let runs = pageRuns.values
        pageRuns = [:]
        for run in runs {
            run.resume(throwing: PluginError.stopped)
        }
    }

    /// Stops the step and the AI requests that belong to it.
    func stop(_ step: PluginHookStep) {
        if let aiRequests { aiRequests.stop(step) } else { step.stop() }
    }

    func setting(_ key: String) -> PluginValue? {
        manager?.setting(key, of: pluginID)
    }

    func setBadge(_ text: String?, onSidebarItem id: String) {
        guard !hasEnded else { return }
        manager?.setBadge(text, onSidebarItem: id, of: pluginID)
    }

    func setEnabled(_ isEnabled: Bool, command id: String) {
        guard !hasEnded else { return }
        manager?.setEnabled(isEnabled, command: id, of: pluginID)
    }

    func showPanel(_ sidebarItemID: String) {
        guard !hasEnded, userCommandCount > 0 else { return }
        manager?.showPanel(sidebarItemID, of: pluginID)
    }

    func copyToClipboard(_ text: String) throws {
        guard !hasEnded else { throw PluginError.stopped }
        try require(.clipboard)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func tabs() throws -> [PluginTab] {
        guard !hasEnded else { throw PluginError.stopped }
        guard let manager else { return [] }
        return manager.personaTabs().map { manager.shown($0, to: grant, of: pluginID) }
    }

    func downloads() throws -> [PluginDownload] {
        guard !hasEnded else { throw PluginError.stopped }
        try require(.downloads)
        return manager?.personaDownloads() ?? []
    }

    func notify(title: String, body: String) throws {
        guard !hasEnded else { throw PluginError.stopped }
        try require(.notifications)
        manager?.notify(pluginID, title: title, body: body)
    }

    func tab(_ id: PluginTab.ID) throws -> PluginTab? {
        try tabs().first { $0.id == id }
    }

    func selectedTab() throws -> PluginTab? {
        guard !hasEnded else { throw PluginError.stopped }
        guard let manager, let tab = manager.selectedTab() else { return nil }
        return manager.shown(tab, to: grant, of: pluginID)
    }

    /// Only a web page opens, so no plugin opens a file, an internal page, or a script address. Opening, closing, selecting, and moving do not belong to the running hook step: they act on the tab as it is when the call arrives, except that once the scheduler has stopped the step, its listener closes, selects, and moves its event's tab no more, as it renames it no more, since by then the tab can show the user's next document.
    func openTab(_ url: URL, _ options: PluginOpenTabOptions) throws -> PluginTab.ID {
        guard !hasEnded else { throw PluginError.stopped }
        try require(.manageTabs)
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host()?.isEmpty == false else {
            throw PluginError.invalidAddress(url.absoluteString)
        }
        guard let manager else { throw PluginError.closed }
        return try manager.openTab(url, options, by: pluginID)
    }

    func closeTab(_ id: PluginTab.ID) throws {
        try manageTab(id, inStep: true) { try $0.closeTab(id, by: pluginID) }
    }

    func panelCloseTab(_ id: PluginTab.ID) throws {
        try manageTab(id, inStep: false) { try $0.closeTab(id, by: pluginID) }
    }

    func selectTab(_ id: PluginTab.ID) throws {
        try manageTab(id, inStep: true) { try $0.selectTab(id, by: pluginID) }
    }

    func panelSelectTab(_ id: PluginTab.ID) throws {
        try manageTab(id, inStep: false) { try $0.selectTab(id, by: pluginID) }
    }

    func moveTab(_ id: PluginTab.ID, to place: PluginTabPlace) throws -> Bool {
        try manageTab(id, inStep: true) { try $0.moveTab(id, to: place, by: pluginID) }
    }

    func panelMoveTab(_ id: PluginTab.ID, to place: PluginTabPlace) throws -> Bool {
        try manageTab(id, inStep: false) { try $0.moveTab(id, to: place, by: pluginID) }
    }

    /// A close, a selection, or a move of the tab, which throws `PluginError.stopped` for the running hook step's tab once the scheduler has stopped the step, unless `inStep` is false, as for a panel's call.
    private func manageTab<Value>(_ id: PluginTab.ID, inStep: Bool, _ change: (PluginManager) throws -> Value) throws -> Value {
        guard !hasEnded else { throw PluginError.stopped }
        try require(.manageTabs)
        guard let manager else { throw PluginError.notGranted(id) }
        if inStep, let step = hookStep, step.tab == id, step.isStopped { throw PluginError.stopped }
        return try change(manager)
    }

    func renameTab(_ id: PluginTab.ID, to name: String?) throws -> Bool {
        try renameTab(id, to: name, inStep: true)
    }

    func panelRenameTab(_ id: PluginTab.ID, to name: String?) throws -> Bool {
        try renameTab(id, to: name, inStep: false)
    }

    /// With `inStep` false, as for a panel's call, the running hook step does not bind the rename.
    private func renameTab(_ id: PluginTab.ID, to name: String?, inStep: Bool) throws -> Bool {
        guard !hasEnded else { throw PluginError.stopped }
        try require(.renameTabs)
        guard let manager, manager.personaTabs().contains(where: { $0.id == id }) else { throw PluginError.notGranted(id) }
        // A rename of the running hook step's tab is for its event's document, which a stopped step no longer renames.
        guard inStep, let step = hookStep, step.tab == id else { return manager.renameTab(id, to: name, showing: nil, by: pluginID) }
        guard !step.isStopped else { return false }
        return manager.renameTab(id, to: name, showing: step.document, by: pluginID)
    }

    /// A manager without an AI interface, as in tests, gives no AI. The client belongs to the hook step that runs now, if any.
    func ai() throws -> any AIClient {
        try aiRequestsInReach().client()
    }

    func panelAI() throws -> any AIClient {
        try aiRequestsInReach().client(inStep: false)
    }

    /// The script runs in the plugin's world through the tab's page, and its value or what it threw comes back only while the tab shows the document that the call checked, and for a plugin with `ai` only while the address it shows is not on a site excluded from AI, as a single-page site can move to one within its document.
    func runPageScript(_ script: PluginScript, in id: PluginTab.ID) async throws -> PluginValue {
        guard !hasEnded else { throw PluginError.stopped }
        guard let manager else { throw PluginError.notGranted(id) }
        let function = try await PluginPageRun.function(running: manager.source(of: script, for: pluginID), sites: grant.sites,
                                                        within: grant.siteAccess == .whenInvoked ? manager.accessSites(of: pluginID, inTab: id) : nil)
        guard !hasEnded else { throw PluginError.stopped }
        let page = try manager.page(of: id, for: grant, of: pluginID)
        let reply = try await run(function, in: page.contents, waitingAtMost: manager.pageRunLimit)
        guard !hasEnded else { throw PluginError.stopped }
        guard let shown = manager.personaTabs().first(where: { $0.id == id }), shown.documentID == page.tab.documentID else { throw PluginError.noPage }
        // What the script returned or threw can hold the page's text.
        guard !manager.excludesAI(shown, for: grant) else { throw PluginError.siteNotGranted }
        switch try PluginPageRun.outcome(of: reply) {
        case .outside: throw PluginError.siteNotGranted
        case let .failed(text): throw PluginError.pageScriptFailed(text)
        case let .value(value): return value
        }
    }

    /// Runs the function in the page's main frame without the user's gesture, or throws `PluginError.pageRunUnavailable` where the engine would give it one, and waits for its reply at most for `limit`: WebKit waits as long as the page runs, also while a script loops in it. A run still unanswered then, or one that the engine fails that late, as Chromium's does once it has waited as long, throws `PluginError.timedOut`; one that the engine fails sooner, as when the tab's page has no document to run in, as a tab that no window has shown yet, throws `noPage`. The wait ends with `stopped` as the context ends.
    private func run(_ function: String, in contents: any EngineWebContents, waitingAtMost limit: Duration) async throws -> String? {
        let number = nextPageRun
        nextPageRun += 1
        let started = ContinuousClock.now
        return try await withCheckedThrowingContinuation { continuation in
            pageRuns[number] = continuation
            contents.executeJavaScriptWithoutUserGesture(function, inWorld: pluginID.pageScriptWorld) { result in
                let settled = result.mapError { error -> PluginError in
                    if error is EngineUserGestureError { return .pageRunUnavailable }
                    return ContinuousClock.now - started < limit ? .noPage : .timedOut
                }
                Task { @MainActor [weak self] in self?.pageRuns.removeValue(forKey: number)?.resume(with: settled) }
            }
            Task { [weak self] in
                try? await Task.sleep(until: started + limit, clock: .continuous)
                self?.pageRuns.removeValue(forKey: number)?.resume(throwing: PluginError.timedOut)
            }
        }
    }

    func postMessage(_ message: PluginValue, toTab id: PluginTab.ID) throws {
        guard !hasEnded else { throw PluginError.stopped }
        guard let manager else { throw PluginError.notGranted(id) }
        let page = try manager.page(of: id, for: grant, of: pluginID)
        do {
            try page.contents.postPageScriptMessage(String(decoding: try JSONEncoder().encode(message), as: UTF8.self), toWorld: pluginID.pageScriptWorld)
        } catch is EngineUserGestureError {
            throw PluginError.pageRunUnavailable
        }
    }

    private func aiRequestsInReach() throws -> PluginAIRequests {
        guard !hasEnded else { throw PluginError.stopped }
        try require(.ai)
        guard let aiRequests else { throw PluginError.permissionDenied(.ai) }
        return aiRequests
    }

    /// `tabs.manage` includes `tabs.rename`.
    private func require(_ permission: PluginPermission) throws {
        guard grant.permissions.contains(permission) || (permission == .renameTabs && grant.permissions.contains(.manageTabs)) else {
            throw PluginError.permissionDenied(permission)
        }
    }
}
