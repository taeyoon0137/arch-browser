// The web extensions of one Persona as a kind of plugin. The runtime reads their packages, has the engines that run extensions check them, loads each enabled extension with what the user granted it into the Persona's profiles in the engines that run its package, a version of a pair only in the engine its record gives it, deletes a removed extension's storage in each engine, in a later launch for an engine that did not run at the removal, and does for those engines what the app does for extensions: it shows their popups, opens the tabs and windows they ask for, asks the user about access they request while they run and the engines' other questions, and relays their native messages. It has Arch look for native apps before it loads an extension that may reach one, and keeps out of Chromium, which reads Arch's links to other browsers' host manifests itself, each version whose identifier Arch cannot prove while a linked native app accepts it (`NativeMessagingHostLinks`). The plugin list stays engine-independent, so that every engine that runs extensions runs the same installs where their packages run.
import AppKit
import ARCHEngine
import Plugins
import UniformTypeIdentifiers

/// What `Browsing` provides so that a Persona's web extensions reach its engines, tabs, and windows.
@MainActor
public protocol WebExtensionHost: AnyObject {
    /// The engines whose runtime runs web extensions on this Mac, each with its extension runtime's version (`Engine.extensionRuntimeVersion`), which engine checks record, read without starting any profile. An engine whose application did not start is not one of them.
    var extensionRuntimeVersions: [EngineKind: String] { get }
    /// The Persona's profiles in the engines that run web extensions, by engine, which the host starts if they have not started. An engine whose application or profile does not start is left out, and no engine's profile stands in for another's.
    func extensionEngines(in persona: PersonaID) -> [EngineKind: any EngineExtensions]
    /// The web contents of the tab while it is open.
    func webContents(ofTab id: UUID) -> (any EngineWebContents)?
    /// Selects the tab in a window, as a click on its row does.
    func activate(_ tab: any EngineWebContents)
    func close(_ tab: any EngineWebContents)
    /// Shows an action's popup from the site settings button of the window that shows the tab, or of the front window for no tab. Returns false when no such window shows.
    func present(_ popup: EngineExtensionPopup, for tab: (any EngineWebContents)?) -> Bool
    /// Opens a tab of the Persona in `engine` that loads `url`, or the new tab page for nil, in the window `windowID`, as the host reports windows, or in the Persona's focused one, at `index` among that window's tabs of the engine, or after its active tab, and selects it when `active`. Completes once the window reports the tab, with its web contents, or with nil when it did not open.
    func openTab(_ url: URL?, in engine: EngineKind, persona: PersonaID, window windowID: UUID?, active: Bool, index: Int?, completion: @escaping ((any EngineWebContents)?) -> Void)
    /// Opens a small window of the Persona whose one tab, in `engine`, loads the address, or the new tab page for none, in front when `focused`, which extensions see with only that tab. Several addresses open nothing, since a small window holds one tab. Completes once the window is reported, with its identity, or with nil when it opens none.
    func openWindow(with urls: [URL], in engine: EngineKind, persona: PersonaID, focused: Bool, completion: @escaping (UUID?) -> Void)
    /// Asks the user the question for the tab, or for the front window's tab for no tab, and answers whether the user agreed. A question that ends without the user, as when its tab closes, answers false.
    func ask(_ question: WebExtensionQuestion, for tab: (any EngineWebContents)?, completion: @escaping (Bool) -> Void)
    /// Starts Arch's install of the extension `id` from the Web Store in the Persona, as the store's own install button on the tab's store page asks: the store sheet in Settings ▸ Plugins, whose review names the Persona with the tab's space (`docs/web-store.md`, Chromium's store button).
    func installFromWebStore(_ id: String, persona: PersonaID, tab: any EngineWebContents)
}

/// An enabled extension's action for one tab, as the site settings popover lists it: one for each plugin, and one for a pair, whose identifier and name are those of its version installed first. An extension without an action in its manifest has one only while the tab's engine keeps it from the tab's site.
public struct WebExtensionActionItem: Identifiable {
    public let id: PluginID
    public let name: String
    /// The action of the version that the tab's engine runs. Nil while the tab's engine runs none of the plugin's versions, as on a tab of an engine that refused its package or runs no web extensions, or before the extension has loaded.
    public let action: EngineExtensionAction?
    /// The engines the plugin's enabled versions run on, for the note on another engine's tab.
    public let engines: Set<EngineKind>
    /// Whether the plugin asks for a version for the tab's engine (see `InstalledPlugin.missingEngine(among:)`).
    public let asksForVersion: Bool
    /// Whether the engine kept the extension from running on the tab's site, so that the user can allow it there (`grantSiteAccess(of:for:)`).
    public var wantsSiteAccess: Bool { action?.wantsSiteAccess == true }
}

@MainActor
public final class WebExtensionRuntime: ObservableObject, PluginRuntime {
    public nonisolated let kind = PluginKind.webExtension
    public nonisolated let manifestFileName = WebExtensionManifest.fileName
    public var onCheck: ((PluginID, [EngineKind: PluginEngineCheck]) -> Void)?
    public var onEngineFailure: ((PluginID, EngineKind, String) -> Void)?
    public var onEnginesChange: (() -> Void)?
    /// `webExtension.json` in the Persona's folder, which keeps the removals that engines missed (`MissedRemoval`). Setting it reads them.
    public var runtimeFile: URL? {
        didSet { missedRemovals = runtimeFile.map(Self.readMissedRemovals) ?? [] }
    }
    private let persona: PersonaID
    private weak var host: (any WebExtensionHost)?
    private let nativeMessaging: NativeMessaging
    /// Arch's links to other browsers' host manifests, which every Persona's runtime shares: the runtime asks for their passes and applies their gate on Chromium.
    private let hostLinks: NativeMessagingHostLinks
    /// The Persona's profiles in the engines that run extensions, from the first extension that is checked, loads, or goes.
    private var attached: [EngineKind: any EngineExtensions]?
    /// The installed extensions, on or off, in the order the user installed them, as the manager last listed them.
    private var plugins: [InstalledPlugin] = []
    /// The extensions each engine runs, with what it loaded.
    private var loaded: [EngineKind: [PluginID: LoadedExtension]] = [:]
    /// The last change to the engines; each waits for the one before, so that loads and unloads reach the engines in order.
    private var engineChange: Task<Void, Never>?
    /// The Persona's windows and the focused one, as the host last reported them, for engines that attach later.
    private var windows: [EngineExtensionWindow] = []
    private var focusedWindowID: UUID?
    /// The installed extensions whose package has had its key written in this run, with the date of the install that wrote it, as an update brings a new package.
    private var keyedPackages: [PluginID: Date] = [:]
    /// The removals whose storage an engine still keeps because it did not run for the Persona when the user removed the extension, in the order they happened, as `runtimeFile` keeps them.
    private var missedRemovals: [MissedRemoval] = []
    /// The identifier of the extension whose store page an address is, or nil for another address, which decides where the store's own install button may start a store install. The tests read store pages on hosts that stand in for the store's.
    var storePageReader: (URL) -> String? = WebStore.extensionID(in:)
    /// The install date of each extension as `run(_:)` last listed them, nil before its first call, which tells an install or an update in this run.
    private var installDates: [PluginID: Date]?
    /// Whether an install or an update in this run of an extension whose grant has `nativeMessaging` waits for Arch to look for native apps again.
    private var looksForNativeAppsAgain = false
    /// The Persona's profiles by engine as the host reported their start, which the gate reaches before the runtime attaches them.
    private var startedProfiles: [EngineKind: any EngineExtensions] = [:]
    /// The load in Chromium under way, which the step before a link changes waits for.
    private var chromiumLoad: Task<Void, any Error>?

    /// `hostLinks` holds Arch's folder of host manifests, which name the native apps extensions may reach, with its links to other browsers' manifests.
    public init(persona: PersonaID, host: any WebExtensionHost, hostLinks: NativeMessagingHostLinks) {
        self.persona = persona
        self.host = host
        self.hostLinks = hostLinks
        nativeMessaging = NativeMessaging(links: hostLinks)
    }

    /// `nativeMessagingHosts` is the folder of the host manifests that name the native apps extensions may reach, without links to other browsers' manifests.
    convenience init(persona: PersonaID, host: any WebExtensionHost, nativeMessagingHosts: URL) {
        self.init(persona: persona, host: host, hostLinks: NativeMessagingHostLinks(directory: nativeMessagingHosts, folders: []))
    }

    public nonisolated func manifest(forPackageAt root: URL, source: URL) throws -> PluginManifest {
        try WebExtensionManifest(packageAt: root, source: source).manifest
    }

    /// The engines that the host reports as running web extensions, with their runtimes' versions, less, once the runtime has attached them, those whose profile did not start for the Persona: WebKit from macOS 15.4, and Chromium.
    public var engines: [EngineKind: String] {
        let versions = host?.extensionRuntimeVersions ?? [:]
        guard let attached else { return versions }
        return versions.filter { attached[$0.key] != nil }
    }

    /// Web extensions are unavailable only while no engine runs them on this Mac.
    public var unavailability: String? {
        guard engines.isEmpty else { return nil }
        guard #available(macOS 15.4, *) else { return "Web extensions need macOS 15.4 or later." }
        return "No engine on this Mac runs web extensions."
    }

    /// Checks the package in each engine that runs extensions, in the order of `EngineKind`, starting the Persona's profile there as loading does.
    public func check(packageAt root: URL) async -> [EngineKind: PluginEngineCheck] {
        guard unavailability == nil else { return [:] }
        var checks: [EngineKind: PluginEngineCheck] = [:]
        for (kind, engine) in orderedEngines() {
            checks[kind] = await Self.check(root, in: engine, of: kind)
        }
        return checks
    }

    private static func check(_ packageURL: URL, in engine: any EngineExtensions, of kind: EngineKind) async -> PluginEngineCheck {
        do {
            try await engine.check(packageURL)
            return .runs
        } catch {
            return .refused("\(kind.displayName) cannot run this extension: \(error.localizedDescription)")
        }
    }

    public func run(_ installed: [InstalledPlugin]) {
        if let installDates, installed.contains(where: { $0.grant.permissions.contains(.nativeMessaging) && installDates[$0.id] != $0.installedAt }) {
            looksForNativeAppsAgain = true
        }
        installDates = Dictionary(installed.compactMap { plugin in plugin.installedAt.map { (plugin.id, $0) } }) { first, _ in first }
        plugins = installed
        changeEngines { await $0.loadEnabledExtensions() }
    }

    /// Answers the engine for a profile of the Persona that has just started. The runtime becomes the profile's delegate at once, before any extension attaches it, so that the store's own install button, which asks before the Persona has an extension, reaches it. On Chromium, which reads Arch's links and its own system folder itself, it then stops each version that the gate refuses by what `NativeMessagingHostLinks` reads there, also one the profile kept from an earlier launch, before any pass of loads ends. Then, while no extension is enabled, it stops what the profile runs from an earlier launch: no pass of loads reaches the profile then, since switched-off extensions alone start no engine, so an extension that the engine kept in the profile, such as one switched off just before the app ended and before the engine wrote that down, would keep running. With an extension enabled, the pass that loads it stops the rest once its loads end. The host calls it as each of the Persona's profiles starts and, when it makes the runtime, for the profiles that started before.
    public func profileDidStart(with extensions: any EngineExtensions, of kind: EngineKind) {
        extensions.delegate = self
        startedProfiles[kind] = extensions
        if kind == .chromium { takeGatedVersionsOut(of: extensions) }
        guard !plugins.contains(where: \.isEnabled) else { return }
        extensions.stopUnloadedExtensions()
    }

    /// The enabled extensions, in the order the user installed them.
    private var enabled: [InstalledPlugin] {
        plugins.filter(\.isEnabled)
    }

    public func makePlugin(_ installed: InstalledPlugin) -> any Plugin {
        WebExtensionPlugin(runtime: self, id: installed.id)
    }

    /// Both engines take a folder or a `.zip` archive, and Chromium also a `.crx` file, the form its packages come in. Whether WebKit's also take app extension bundles is open.
    public func packageTypes(for engine: EngineKind) -> [UTType] {
        engine == .chromium ? [.folder, .zip, PluginPackage.crxType] : [.folder, .zip]
    }

    /// Takes the extension out of the engines that loaded it and deletes its storage in every engine, except in one where another plugin with the same engine identifier keeps it: the engine that the pair's record gives the counterpart, whether or not the counterpart is on, or one that loaded the other plugin. An engine that does not run for the Persona in this launch, as when its application or the Persona's profile did not start, and every engine while none runs extensions, misses the removal: `runtimeFile` keeps it until the first pass after that engine attaches in a later launch deletes the storage there.
    public func remove(_ installed: InstalledPlugin) {
        let id = Self.extensionID(of: installed)
        let others = plugins.filter { $0.id != installed.id && Self.extensionID(of: $0) == id }
        plugins.removeAll { $0.id == installed.id }
        guard unavailability == nil else {
            return noteMissedRemoval(of: id, on: EngineKind.allCases.filter { kind in !others.contains { $0.pairEngine == kind } })
        }
        changeEngines { runtime in
            await runtime.removeMissedData(in: runtime.orderedEngines())
            var cleared: [any EngineExtensions] = []
            var missed: [EngineKind] = []
            for kind in EngineKind.allCases {
                let engine = runtime.attached?[kind]
                if let engine, runtime.loaded[kind]?.removeValue(forKey: installed.id) != nil { engine.unload(id) }
                guard !others.contains(where: { $0.pairEngine == kind || runtime.loaded[kind]?[$0.id] != nil }) else { continue }
                if let engine { cleared.append(engine) } else { missed.append(kind) }
            }
            runtime.noteMissedRemoval(of: id, on: missed)
            for engine in cleared { await engine.removeData(of: id) }
        }
    }

    /// Keeps in `runtimeFile` that the engines of `kinds`, which did not run for the Persona, still keep the storage of the extension with the engine identifier `id`.
    private func noteMissedRemoval(of id: String, on kinds: [EngineKind]) {
        let new = kinds.map { MissedRemoval(engine: $0.rawValue, id: id) }.filter { !missedRemovals.contains($0) }
        guard !new.isEmpty else { return }
        missedRemovals += new
        saveMissedRemovals()
    }

    /// Deletes in each of `engines`, the attached engines, the storage of the extensions that the user removed in an earlier launch in which the engine did not run for the Persona, then drops those removals from `runtimeFile`. Each pass does so before it loads anything, so that an extension installed again with the same identifier starts without the removed one's storage. A removal that names an engine this build does not know stays in the file.
    private func removeMissedData(in engines: [(EngineKind, any EngineExtensions)]) async {
        var due: [(removal: MissedRemoval, engine: any EngineExtensions)] = []
        for removal in missedRemovals {
            guard let engine = engines.first(where: { $0.0.rawValue == removal.engine })?.1 else { continue }
            due.append((removal, engine))
        }
        guard !due.isEmpty else { return }
        for (removal, engine) in due { await engine.removeData(of: removal.id) }
        missedRemovals.removeAll { removal in due.contains { $0.removal == removal } }
        saveMissedRemovals()
    }

    /// Whether a removal waits for an engine that the host lists as running extensions, so that a pass attaches the engines although no extension is enabled.
    private var hasMissedRemovalsForListedEngines: Bool {
        let listed = Set(engines.keys.map(\.rawValue))
        return missedRemovals.contains { listed.contains($0.engine) }
    }

    /// The removals in the file at `url`. A missing file has none, and so has one that does not read or decode, which the next change replaces: it names only storage to delete, so losing it leaves that storage in the engines until the user deletes the Persona.
    private static func readMissedRemovals(at url: URL) -> [MissedRemoval] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode(WebExtensionRuntimeFile.self, from: data))?.missedRemovals ?? []
    }

    /// Writes the removals to `runtimeFile` atomically, or deletes the file once none is left. A write that fails, as on a full disk, keeps them for the run only.
    private func saveMissedRemovals() {
        guard let runtimeFile else { return }
        if missedRemovals.isEmpty {
            try? FileManager.default.removeItem(at: runtimeFile)
        } else if let data = try? JSONEncoder().encode(WebExtensionRuntimeFile(missedRemovals: missedRemovals)) {
            try? data.write(to: runtimeFile, options: .atomic)
        }
    }

    /// The identifier the engines know the extension by: its package's, without the ending of a version's plugin identifier.
    private static func extensionID(of installed: InstalledPlugin) -> String {
        WebExtensionManifest.extensionID(of: installed.manifest.id)
    }

    /// The name of the installed extension, on or off, whose page is at `url`, as its options page in a tab, or, for a version of a pair, the pair's name, its version installed first's, without spaces at either end; nil for any other address, and for a name with nothing else, as a localized name whose message is empty, so that the identifier shows instead. Both engines address an extension's pages under a scheme of their own outside the web schemes, with the identifier they know the extension by as the host, which the address pill shows the name in place of.
    public func name(ofPageAt url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), !EngineURLSchemes.web.contains(scheme), let host = url.host?.lowercased(), !host.isEmpty,
              let installed = plugins.first(where: { Self.extensionID(of: $0) == host }) else { return nil }
        let name = (plugins.first { $0.id == installed.id || $0.id == installed.counterpart } ?? installed).manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Waits until the changes to the engines asked for so far, and those they lead to, are done.
    func waitForEngines() async {
        while let change = engineChange {
            await change.value
            if engineChange == change { return }
        }
    }

    /// Runs `change` after the changes before it, on a Mac where extensions run. The change keeps the runtime until it is done, so that the extensions of a Persona the user deleted still leave the engines.
    private func changeEngines(_ change: @escaping @MainActor (WebExtensionRuntime) async -> Void) {
        guard unavailability == nil else { return }
        let previous = engineChange
        engineChange = Task {
            await previous?.value
            await change(self)
        }
    }

    /// What one engine loaded for an extension. An update gives the install a new date, so that the engine loads the new package.
    private struct LoadedExtension {
        let installed: InstalledPlugin
        let engineExtension: EngineExtension

        /// Whether the engine loaded what it would load now, which carries the install's date. The engines' answers and failures do not count, so that recording them leaves a running copy alone.
        func matches(_ engineExtension: EngineExtension) -> Bool {
            self.engineExtension == engineExtension
        }
    }

    /// First has Arch look for native apps where the extensions need it (`lookForNativeApps()`). Then deletes in each engine the storage of the extensions removed in an earlier launch in which the engine did not run (`removeMissedData(in:)`). Then, in each engine, unloads the extensions that are no longer enabled, whose install changed, that no longer run there, whose pair gives the engine to the other version, or that the gate keeps out of Chromium. Then, for each installed extension, on or off, the engines check its package where it has no current answer and is not loaded, and every engine checks again the package of an enabled extension that no engine runs by its current answers, so that the manager, which records each answer, switches it off with why. Each enabled extension then loads in each engine that runs it where it is not loaded, a version of a pair only in the engine its record gives it, and no engine loads two extensions with one engine identifier; Chromium does not load a version that the gate refuses, which the manager keeps the gate's sentence for as a failure to start there. An extension that an engine cannot start goes out of that engine, and the manager keeps why. Once every load has ended, each engine stops what it runs from an earlier launch and the pass did not load. Switched-off extensions alone start no engine: their packages are checked once the engines run for an enabled extension, a staging, or a removal that waits for an engine the host lists.
    private func loadEnabledExtensions() async {
        await lookForNativeApps()
        let plugins = plugins
        guard plugins.contains(where: \.isEnabled) || attached != nil || hasMissedRemovalsForListedEngines else { return }
        let engines = orderedEngines()
        await removeMissedData(in: engines)
        for installed in plugins where keyedPackages[installed.id] != installed.installedAt {
            Self.writeKey(of: installed)
            keyedPackages[installed.id] = installed.installedAt
        }
        var extensions: [PluginID: (installed: InstalledPlugin, engineExtension: EngineExtension)] = [:]
        for installed in plugins where extensions[installed.id] == nil {
            extensions[installed.id] = Self.engineExtension(installed).map { (installed: installed, engineExtension: $0) }
        }
        for (kind, engine) in engines {
            for (id, load) in loaded[kind] ?? [:] {
                var refusal: String?
                // A loaded copy stays until its engine answers that it does not run the package; a load needs the engine's answer that it does.
                if let wanted = extensions[id], wanted.installed.isEnabled, load.matches(wanted.engineExtension), Self.runs(wanted.installed, on: kind, keepingUnanswered: true) {
                    refusal = kind == .chromium ? gateRefusal(of: wanted.installed) : nil
                    if refusal == nil { continue }
                }
                engine.unload(load.engineExtension.id)
                loaded[kind]?[id] = nil
                if let refusal { onEngineFailure?(id, kind, refusal) }
            }
        }
        for installed in plugins {
            guard let engineExtension = extensions[installed.id]?.engineExtension else { continue }
            // An enabled extension that runs nowhere by its current answers, as one switched on again after every engine refused it, is checked again everywhere.
            let checksEveryEngine = installed.isEnabled && !engines.contains { kind, _ in installed.engineChecks[kind] == true || loaded[kind]?[installed.id] != nil }
            // Every answer reaches the manager before any failure to start, so that it knows each engine the extension runs on.
            var checks: [EngineKind: PluginEngineCheck] = [:]
            for (kind, engine) in engines where loaded[kind]?[installed.id] == nil && (checksEveryEngine || installed.engineChecks[kind] == nil) {
                checks[kind] = await Self.check(engineExtension.packageURL, in: engine, of: kind)
            }
            if !checks.isEmpty { onCheck?(installed.id, checks) }
            guard installed.isEnabled else { continue }
            for (kind, engine) in engines where loaded[kind]?[installed.id] == nil {
                guard Self.runs(installed, on: kind, checks: checks),
                      !(loaded[kind] ?? [:]).values.contains(where: { $0.engineExtension.id == engineExtension.id }) else { continue }
                if kind == .chromium, let refusal = gateRefusal(of: installed) {
                    // Stops a copy that the profile kept from an earlier launch.
                    engine.unload(engineExtension.id)
                    onEngineFailure?(installed.id, kind, refusal)
                    continue
                }
                do {
                    try await load(engineExtension, of: installed, into: engine, of: kind)
                } catch {
                    engine.unload(engineExtension.id)
                    onEngineFailure?(installed.id, kind, "Arch could not start it on \(kind.displayName) tabs: \(error.localizedDescription)")
                }
            }
        }
        for (_, engine) in engines { engine.stopUnloadedExtensions() }
        objectWillChange.send()
    }

    /// Loads the extension in the engine and records what it loaded. A load in Chromium stays in `chromiumLoad` until it ends, so that the step before a link changes can wait for it and find it recorded.
    private func load(_ engineExtension: EngineExtension, of installed: InstalledPlugin, into engine: any EngineExtensions, of kind: EngineKind) async throws {
        let load = Task {
            try await engine.load(engineExtension)
            loaded[kind, default: [:]][installed.id] = LoadedExtension(installed: installed, engineExtension: engineExtension)
        }
        guard kind == .chromium else { return try await load.value }
        chromiumLoad = load
        defer { if chromiumLoad == load { chromiumLoad = nil } }
        try await load.value
    }

    // MARK: Native apps

    /// Has Arch look for native apps before the loads: again after an install or an update in this run of an extension whose grant has `nativeMessaging`, and otherwise once per run while an enabled extension's grant has it, so that the gate knows Arch's links before such an extension loads.
    private func lookForNativeApps() async {
        if looksForNativeAppsAgain {
            looksForNativeAppsAgain = false
            await hostLinks.update(force: true)
        } else if plugins.contains(where: { $0.isEnabled && $0.grant.permissions.contains(.nativeMessaging) }) {
            await hostLinks.update()
        }
    }

    /// The gate's sentence for the version on Chromium, which reads Arch's links and its own system folder itself: for a version whose grant has `nativeMessaging`, whose identifier Arch cannot prove, and which a manifest behind one of Arch's links, one that a pass is about to make, or one in Chromium's folder allows, as a manifest that does not read counts. Nil lets it run there.
    private func gateRefusal(of installed: InstalledPlugin) -> String? {
        guard installed.grant.permissions.contains(.nativeMessaging) else { return nil }
        return hostLinks.refusal(of: NativeMessagingCaller(installed))
    }

    /// Takes out of the Chromium profile each version that may run there, outside a pair or as its pair's Chromium version, and that the gate refuses: one the runtime loaded leaves with the gate's sentence as its failure on Chromium, and a copy that the profile kept from an earlier launch stops.
    private func takeGatedVersionsOut(of chromium: any EngineExtensions) {
        for installed in plugins where installed.pairEngine == nil || installed.pairEngine == .chromium {
            guard let refusal = gateRefusal(of: installed) else { continue }
            let id = Self.extensionID(of: installed)
            if let load = loaded[.chromium]?.removeValue(forKey: installed.id) {
                chromium.unload(load.engineExtension.id)
                onEngineFailure?(installed.id, .chromium, refusal)
            } else if !(loaded[.chromium] ?? [:]).values.contains(where: { $0.engineExtension.id == id }) {
                chromium.unload(id)
            }
        }
    }

    /// The step when the gate of `NativeMessagingHostLinks` comes to refuse more callers (`gateWidens`), before a pass creates or changes a link and after one reads more origins behind a link it keeps, which the session asks of every Persona's runtime: takes out of Chromium the versions that the gate refuses, the links the pass will make included, and stops what Chromium runs that the runtime has not loaded: a copy that the profile kept of an extension that the list lacks, whose identifier the gate cannot check, and, before the run's first pass of loads ends, the kept copies that the pass then loads again. It then waits for a load in Chromium under way and takes it out too if the gate refuses it, and waits until Chromium has switched all of it off (`EngineExtensions.waitForUnloads()`), which Chromium does only once the profile's extensions have loaded, after it has started the copies it kept, so that no such version runs there once the link exists. It does not wait for the runtime's changes to the engines, since its own pass of loads may be the one that asked for the links.
    public func takeGatedVersionsOutOfChromium() async {
        guard let chromium = attached?[.chromium] ?? startedProfiles[.chromium] else { return }
        takeGatedVersionsOut(of: chromium)
        chromium.stopUnloadedExtensions()
        if let load = chromiumLoad {
            _ = try? await load.value
            takeGatedVersionsOut(of: chromium)
        }
        await chromium.waitForUnloads()
    }

    /// What the native messages and ports of the Persona's extensions last met on WebKit tabs in this run, by plugin, which Settings ▸ Plugins shows (`NativeAppGuide`).
    public var nativeAppOutcomes: NativeAppOutcomes { nativeMessaging.outcomes }

    /// Whether the extension runs on the engine of `kind` by the rule Settings shows (`InstalledPlugin.engines`), with the engine's answer in this pass, `checks`, where it checked the package, and, while the engine has no answer, the answer `keepingUnanswered`.
    private static func runs(_ installed: InstalledPlugin, on kind: EngineKind, checks: [EngineKind: PluginEngineCheck] = [:], keepingUnanswered: Bool = false) -> Bool {
        var answered = installed
        if let check = checks[kind] { answered.engineChecks[kind] = check == .runs }
        if answered.engineChecks[kind] == nil { answered.engineChecks[kind] = keepingUnanswered }
        return answered.engines.contains(kind)
    }

    /// Writes into the package of an extension installed from a file without a `key` in its manifest the key that gives each engine Arch's identifier for it, as `WebExtensionManifest.writeKey(packageAt:source:)` does. A package that cannot be written keeps its manifest, and Chromium then refuses to load it under another identifier.
    private static func writeKey(of installed: InstalledPlugin) {
        guard let packageURL = installed.packageURL, case let .file(source) = installed.origin else { return }
        try? WebExtensionManifest.writeKey(packageAt: packageURL, source: source)
    }

    /// The extension as the engines load it: its package with the date of its install, the API permissions its grant covers with those that come with the install, and its granted sites. Every web page, which Arch's patterns write as `*://*/*`, goes as `<all_urls>`, which covers `*://*/*` and which extensions check for with `permissions.contains`; WebKit's `<all_urls>` reaches no file pages.
    private static func engineExtension(_ installed: InstalledPlugin) -> EngineExtension? {
        guard let packageURL = installed.packageURL else { return nil }
        let mapped = WebExtensionManifest.mappedPermissions.filter { installed.grant.permissions.contains($0.value) }.keys
        let sites = installed.grant.sites.map { $0.description == "*://*/*" ? "<all_urls>" : $0.description }
        return EngineExtension(id: extensionID(of: installed), packageURL: packageURL,
                               permissions: Set(installed.manifest.extensionPermissions).union(mapped), sites: Set(sites), installedAt: installed.installedAt)
    }

    /// The Persona's engines that run extensions, in the order of `EngineKind`, attached at first use with the runtime as their delegate and the windows the host reported.
    private func orderedEngines() -> [(EngineKind, any EngineExtensions)] {
        let engines = attached ?? attach()
        return EngineKind.allCases.compactMap { kind in engines[kind].map { (kind, $0) } }
    }

    /// Tells the manager when an engine that `engines` listed did not start the Persona's profile, so that it no longer counts the engine's answers.
    private func attach() -> [EngineKind: any EngineExtensions] {
        let listed = Set(self.engines.keys)
        let engines = host?.extensionEngines(in: persona) ?? [:]
        for engine in engines.values {
            engine.delegate = self
            engine.setWindows(windows, focusedWindowID: focusedWindowID)
        }
        attached = engines
        if Set(self.engines.keys) != listed { onEnginesChange?() }
        return engines
    }

    /// The enabled version of the plugin or its pair that the tab's engine runs, with that engine, while the engine has an action of it for the tab.
    private func versionRunningAction(of id: PluginID, for tab: any EngineWebContents) -> (installed: InstalledPlugin, engine: any EngineExtensions)? {
        let counterpart = plugins.first { $0.id == id }?.counterpart
        guard let engine = attached?[tab.engineKind] else { return nil }
        for installed in enabled where installed.id == id || installed.id == counterpart {
            if loaded[tab.engineKind]?[installed.id] != nil, engine.action(of: Self.extensionID(of: installed), for: tab) != nil { return (installed, engine) }
        }
        return nil
    }

    // MARK: Windows and actions

    /// The Persona's windows and the focused one, if it is the Persona's, each time they change.
    public func setWindows(_ windows: [EngineExtensionWindow], focusedWindowID: UUID?) {
        self.windows = windows
        self.focusedWindowID = focusedWindowID
        attached?.values.forEach { $0.setWindows(windows, focusedWindowID: focusedWindowID) }
    }

    /// The actions of the enabled extensions for the tab, in the order the user installed them, a pair once at its version installed first with the action of the version that the tab's engine runs: of each extension whose manifest, or a version's of a pair, has an action, and of one without while the tab's engine keeps it from the tab's site, as Chromium gives such an extension an action, so that the user can allow it there.
    public func actions(for tab: any EngineWebContents) -> [WebExtensionActionItem] {
        let running = Set(engines.keys)
        var items: [WebExtensionActionItem] = []
        for installed in plugins where plugins.first(where: { $0.id == installed.id || $0.id == installed.counterpart })?.id == installed.id {
            let versions = enabled.filter { $0.id == installed.id || $0.id == installed.counterpart }
            guard !versions.isEmpty else { continue }
            let action = versionRunningAction(of: installed.id, for: tab).flatMap { $0.engine.action(of: Self.extensionID(of: $0.installed), for: tab) }
            let hasAction = versions.contains { $0.manifest.contributions.commands.contains { $0.id == WebExtensionManifest.actionCommand } }
            guard hasAction || action?.wantsSiteAccess == true else { continue }
            items.append(WebExtensionActionItem(id: installed.id, name: installed.manifest.name, action: action, engines: versions.reduce(into: []) { $0.formUnion($1.engines) },
                                                asksForVersion: installed.missingEngine(among: running) == tab.engineKind))
        }
        return items
    }

    /// Runs the action of the extension, or of the version of its pair that the tab's engine runs, for the tab. Returns false when none does, as on a tab of an engine without extensions.
    @discardableResult
    public func performAction(of id: PluginID, for tab: any EngineWebContents) -> Bool {
        guard let version = versionRunningAction(of: id, for: tab) else { return false }
        version.engine.performAction(of: Self.extensionID(of: version.installed), for: tab)
        return true
    }

    /// Allows the extension, or the version of its pair that the tab's engine runs, on the tab's site, where the engine kept it from running.
    public func grantSiteAccess(of id: PluginID, for tab: any EngineWebContents) {
        guard let version = versionRunningAction(of: id, for: tab) else { return }
        version.engine.grantSiteAccess(of: Self.extensionID(of: version.installed), for: tab)
    }

    /// Runs the action of the extension on an open tab, for its command in the palette.
    fileprivate func performAction(of id: PluginID, onTab tabID: UUID) -> Bool {
        guard let tab = host?.webContents(ofTab: tabID) else { return false }
        return performAction(of: id, for: tab)
    }

    /// The engine whose extensions `extensions` are.
    private func engineKind(of extensions: any EngineExtensions) -> EngineKind? {
        attached?.first { $0.value === extensions }?.key
    }

    /// The extension with the engine identifier that the calling engine loaded, which for two versions with one identifier is the version for that engine, while its grant has `permission`.
    private func loadedExtension(_ extensionID: String, in engine: any EngineExtensions, granted permission: PluginPermission? = nil) -> InstalledPlugin? {
        guard let kind = attached?.first(where: { $0.value === engine })?.key,
              let installed = loaded[kind]?.values.first(where: { $0.engineExtension.id == extensionID })?.installed else { return nil }
        if let permission, !installed.grant.permissions.contains(permission) { return nil }
        return installed
    }
}

extension WebExtensionRuntime: @preconcurrency EngineExtensionsDelegate {
    public func extensions(_ extensions: any EngineExtensions, activate tab: any EngineWebContents) {
        host?.activate(tab)
    }

    public func extensions(_ extensions: any EngineExtensions, close tab: any EngineWebContents) {
        host?.close(tab)
    }

    public func extensions(_ extensions: any EngineExtensions, didUpdateActionOf id: String) {
        objectWillChange.send()
    }

    public func extensions(_ extensions: any EngineExtensions, present popup: EngineExtensionPopup, ofExtension id: String, for tab: (any EngineWebContents)?) -> Bool {
        host?.present(popup, for: tab) ?? false
    }

    /// The tab opens in the Persona with the calling engine, which lists it once the window reports it.
    public func extensions(_ extensions: any EngineExtensions, openTabWith url: URL?, inWindow windowID: UUID?, active: Bool, index: Int?,
                           completion: @escaping ((any EngineWebContents)?) -> Void) {
        guard let host, let kind = engineKind(of: extensions) else { return completion(nil) }
        host.openTab(url, in: kind, persona: persona, window: windowID, active: active, index: index, completion: completion)
    }

    public func extensions(_ extensions: any EngineExtensions, openWindowWith urls: [URL], focused: Bool, completion: @escaping (UUID?) -> Void) {
        guard let host, let kind = engineKind(of: extensions) else { return completion(nil) }
        host.openWindow(with: urls, in: kind, persona: persona, focused: focused, completion: completion)
    }

    /// A reload asks on its tab, whose Reload the engine follows. More access in the engine's own sentences asks as access does, naming the version of a pair, for the version that the calling engine loaded: Touch ID or the login password confirm it when what the extension may ask for at run time, its optional access and the sites its install left out, includes every website, and an extension that may ask for native messaging at run time without the install's grant, or whose optional access does not read, is refused, as Arch never grants native messaging at run time and the engine's sentences do not say which permissions they stand for. An install is refused, so that the engine installs nothing outside the plugin list; from a tab on a store page, it starts Arch's store install of the identifier in the Persona with the tab instead, whose review comes before anything installs.
    public func extensions(_ extensions: any EngineExtensions, extension id: String, asks prompt: EngineExtensionPrompt, completion: @escaping (Bool) -> Void) {
        guard let host else { return completion(false) }
        switch prompt.kind {
        case .install:
            completion(false)
            guard let tab = prompt.tab, let page = tab.url, storePageReader(page) != nil, let storeID = WebStore.identifier(id) else { return }
            host.installFromWebStore(storeID, persona: persona, tab: tab)
        case let .reload(names):
            host.ask(WebExtensionEnginePrompt.reloadQuestion(names: names), for: prompt.tab, completion: completion)
        case let .permissions(messages):
            guard let loaded = loadedExtension(id, in: extensions), let kind = engineKind(of: extensions) else { return completion(false) }
            let installed = plugins.first { $0.id == loaded.id } ?? loaded
            let lead = plugins.first { $0.id == installed.id || $0.id == installed.counterpart } ?? installed
            guard let requestable = WebExtensionManifest.runTimeAccess(of: installed),
                  !requestable.permissions.contains("nativeMessaging") || installed.grant.permissions.contains(.nativeMessaging) else { return completion(false) }
            var question = WebExtensionEnginePrompt.permissionsQuestion(messages: messages, extensionName: lead.manifest.name, version: installed.pairEngine, engine: kind,
                                                                       confirmsNext: requestable.grant.confirmationReason(for: lead.manifest.name) != nil)
            question.pluginID = lead.id
            host.ask(question, for: prompt.tab) { allowed in
                guard allowed else { return completion(false) }
                Task { completion(await WebExtensionEnginePrompt.confirm(requestable.grant, extensionName: lead.manifest.name)) }
            }
        }
    }

    /// Asks on the tab, naming for a version of a pair the pair and the calling engine's version, whose copy alone the answer reaches. Access that reaches every website also needs Touch ID or the login password, as at install. Native messaging is never granted here.
    public func extensions(_ extensions: any EngineExtensions, extension id: String, requests access: Set<EngineExtensionAccess>, in tab: (any EngineWebContents)?,
                           completion: @escaping (Set<EngineExtensionAccess>) -> Void) {
        guard let host, let loaded = loadedExtension(id, in: extensions) else { return completion([]) }
        // The pair as the manager last listed it, since separating leaves a running copy loaded as it was.
        let installed = plugins.first { $0.id == loaded.id } ?? loaded
        let lead = plugins.first { $0.id == installed.id || $0.id == installed.counterpart } ?? installed
        let prompt = WebExtensionAccessPrompt(requested: access, extensionName: lead.manifest.name, version: installed.pairEngine)
        guard !prompt.access.isEmpty else { return completion([]) }
        var question = prompt.question()
        question.pluginID = lead.id
        host.ask(question, for: tab) { allowed in
            guard allowed else { return completion([]) }
            Task { completion(await prompt.confirm() ? prompt.access : []) }
        }
    }

    /// Needs the version's `nativeMessaging` grant, and under one of Arch's links the proof of its identifier.
    public func extensions(_ extensions: any EngineExtensions, extension id: String, sendNativeMessage message: Data, toApplication application: String?,
                           reply: @escaping (Result<Data, any Error>) -> Void) {
        guard let installed = loadedExtension(id, in: extensions, granted: .nativeMessaging) else { return reply(.failure(PluginError.permissionDenied(.nativeMessaging))) }
        nativeMessaging.send(message, to: application, from: NativeMessagingCaller(installed), reply: reply)
    }

    /// Needs the version's `nativeMessaging` grant, and under one of Arch's links the proof of its identifier.
    public func extensions(_ extensions: any EngineExtensions, extension id: String, connect port: any EngineNativeMessagingPort) throws {
        guard let installed = loadedExtension(id, in: extensions, granted: .nativeMessaging) else { throw PluginError.permissionDenied(.nativeMessaging) }
        try nativeMessaging.connect(port, from: NativeMessagingCaller(installed))
    }
}

/// `webExtension.json` in the Persona's folder, as `WebExtensionRuntime.runtimeFile` keeps it: `{"missedRemovals": [{"engine": "chromium", "id": "<engine identifier>"}]}`.
private struct WebExtensionRuntimeFile: Codable {
    var missedRemovals: [MissedRemoval]
}

/// An extension's removal that an engine missed, since it did not run for the Persona then: the engine, by its `EngineKind` raw value, kept as text so that a name this build does not know survives its writes, and the engine identifier of the extension whose storage that engine still keeps.
private struct MissedRemoval: Codable, Hashable {
    var engine: String
    var id: String
}

/// A web extension's instance in the plugin system, which runs its action from the palette. The extension itself runs in the engines while it is enabled, whether or not an instance exists.
@MainActor
private final class WebExtensionPlugin: Plugin {
    private weak var runtime: WebExtensionRuntime?
    private let id: PluginID

    init(runtime: WebExtensionRuntime, id: PluginID) {
        self.runtime = runtime
        self.id = id
    }

    func activate(in context: any PluginContext) async throws {}

    /// Throws `noPage` without a tab whose engine runs the extension, so that the manager beeps.
    func run(_ command: String, _ invocation: PluginInvocation) async throws {
        guard command == WebExtensionManifest.actionCommand, let tabID = invocation.tab?.id, runtime?.performAction(of: id, onTab: tabID) == true else {
            throw PluginError.noPage
        }
    }
}
