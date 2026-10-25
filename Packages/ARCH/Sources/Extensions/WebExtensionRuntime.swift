// The web extensions of one Persona as a kind of plugin. The runtime reads their packages, has the engines that run extensions check them, loads each enabled extension with what the user granted it into the Persona's profiles in the engines that run its package, and does for those engines what the app does for extensions: it shows their popups, asks the user about access they request while they run, and relays their native messages. The plugin list stays engine-independent, so that every engine that runs extensions runs the same installs where their packages run.
import AppKit
import ARCHEngine
import Plugins

/// What `Browsing` provides so that a Persona's web extensions reach its engines, tabs, and windows.
@MainActor
public protocol WebExtensionHost: AnyObject {
    /// The engines whose runtime runs web extensions on this Mac, each with its runtime's version, read without starting any profile. An engine whose application did not start is not one of them.
    var extensionEngineVersions: [EngineKind: String] { get }
    /// The Persona's profiles in the engines that run web extensions, by engine, which the host starts if they have not started. An engine whose application or profile does not start is left out, and no engine's profile stands in for another's.
    func extensionEngines(in persona: PersonaID) -> [EngineKind: any EngineExtensions]
    /// The web contents of the tab while it is open.
    func webContents(ofTab id: UUID) -> (any EngineWebContents)?
    /// Selects the tab in a window, as a click on its row does.
    func activate(_ tab: any EngineWebContents)
    func close(_ tab: any EngineWebContents)
    /// Shows an action's popover from the site settings button of the window that shows the tab, or of the front window for no tab. Returns false when no such window shows.
    func present(_ popup: NSPopover, for tab: (any EngineWebContents)?) -> Bool
    /// Shows the alert as a sheet for the tab, or for the front window's tab for no tab, and answers with the button the user chose.
    func presentSheet(_ alert: NSAlert, for tab: (any EngineWebContents)?, completion: @escaping (NSApplication.ModalResponse) -> Void)
}

/// An enabled extension's action for one tab, as the site settings popover lists it.
public struct WebExtensionActionItem: Identifiable {
    public let id: PluginID
    public let name: String
    /// Nil while the tab's engine does not run the extension, as on a Chromium tab or one whose engine refused its package, or before the extension has loaded.
    public let action: EngineExtensionAction?
}

@MainActor
public final class WebExtensionRuntime: ObservableObject, PluginRuntime {
    public nonisolated let kind = PluginKind.webExtension
    public nonisolated let manifestFileName = WebExtensionManifest.fileName
    public var onFailure: ((PluginID, String) -> Void)?
    public var onCheck: ((PluginID, [EngineKind: PluginEngineCheck]) -> Void)?
    public var onEngineFailure: ((PluginID, EngineKind, String) -> Void)?
    public var onEnginesChange: (() -> Void)?
    private let persona: PersonaID
    private weak var host: (any WebExtensionHost)?
    private let nativeMessaging: NativeMessaging
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

    /// `nativeMessagingHosts` is the folder of the host manifests that name the native apps extensions may reach.
    public init(persona: PersonaID, host: any WebExtensionHost, nativeMessagingHosts: URL) {
        self.persona = persona
        self.host = host
        nativeMessaging = NativeMessaging(directory: nativeMessagingHosts)
    }

    public nonisolated func manifest(forPackageAt root: URL, source: URL) throws -> PluginManifest {
        try WebExtensionManifest(packageAt: root, source: source).manifest
    }

    /// The engines that the host reports as running web extensions, with their runtimes' versions, less, once the runtime has attached them, those whose profile did not start for the Persona: WebKit from macOS 15.4; Chromium does not run them yet.
    public var engines: [EngineKind: String] {
        let versions = host?.extensionEngineVersions ?? [:]
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
        plugins = installed
        changeEngines { await $0.loadEnabledExtensions() }
    }

    /// The enabled extensions, in the order the user installed them.
    private var enabled: [InstalledPlugin] {
        plugins.filter(\.isEnabled)
    }

    public func makePlugin(_ installed: InstalledPlugin) -> any Plugin {
        WebExtensionPlugin(runtime: self, id: installed.id)
    }

    /// Takes the extension out of every engine and deletes its storage there.
    public func remove(_ installed: InstalledPlugin) {
        plugins.removeAll { $0.id == installed.id }
        changeEngines { runtime in
            let id = WebExtensionManifest.extensionID(of: installed.id)
            let engines = runtime.orderedEngines()
            for (kind, engine) in engines {
                engine.unload(id)
                runtime.loaded[kind]?[installed.id] = nil
            }
            for (_, engine) in engines { await engine.removeData(of: id) }
        }
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

        /// Whether the engine loaded what it would load for `installed`. The engines' answers and failures do not count, so that recording them leaves a running copy alone.
        func matches(_ installed: InstalledPlugin, _ engineExtension: EngineExtension) -> Bool {
            self.engineExtension == engineExtension && self.installed.installedAt == installed.installedAt
        }
    }

    /// In each engine, unloads the extensions that are no longer enabled, whose install changed, or that no longer run there. Then, for each installed extension, on or off, the engines check its package where it has no current answer and is not loaded, and every engine checks again the package of an enabled extension that no engine runs by its current answers, so that the manager, which records each answer, switches it off with why. Each enabled extension then loads in each engine that runs it where it is not loaded. An extension that an engine cannot start goes out of that engine, and the manager keeps why. Switched-off extensions alone start no engine: their packages are checked once the engines run for an enabled extension or a staging.
    private func loadEnabledExtensions() async {
        let plugins = plugins
        guard plugins.contains(where: \.isEnabled) || attached != nil else { return }
        let engines = orderedEngines()
        var extensions: [PluginID: (installed: InstalledPlugin, engineExtension: EngineExtension)] = [:]
        for installed in plugins where extensions[installed.id] == nil {
            extensions[installed.id] = Self.engineExtension(installed).map { (installed: installed, engineExtension: $0) }
        }
        for (kind, engine) in engines {
            for (id, load) in loaded[kind] ?? [:] {
                if let wanted = extensions[id], wanted.installed.isEnabled, load.matches(wanted.installed, wanted.engineExtension),
                   wanted.installed.engineChecks[kind] != false, wanted.installed.engineFailures[kind] == nil { continue }
                engine.unload(load.engineExtension.id)
                loaded[kind]?[id] = nil
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
            for (kind, engine) in engines where loaded[kind]?[installed.id] == nil && installed.engineFailures[kind] == nil {
                guard Self.runs(installed, on: kind, checks: checks) else { continue }
                do {
                    try await engine.load(engineExtension)
                    loaded[kind, default: [:]][installed.id] = LoadedExtension(installed: installed, engineExtension: engineExtension)
                } catch {
                    engine.unload(engineExtension.id)
                    onEngineFailure?(installed.id, kind, "Arch could not start it on \(kind.displayName) tabs: \(error.localizedDescription)")
                }
            }
        }
        objectWillChange.send()
    }

    /// Whether the engine of `kind` runs the extension's package: by the answer it gave in this pass, `checks`, if it checked the package, else by its current answer, and not without one.
    private static func runs(_ installed: InstalledPlugin, on kind: EngineKind, checks: [EngineKind: PluginEngineCheck]) -> Bool {
        if let check = checks[kind] { return check == .runs }
        return installed.engineChecks[kind] == true
    }

    /// The extension as the engines load it: its package, the API permissions its grant covers with those that come with the install, and its granted sites. Every web page, which Arch's patterns write as `*://*/*`, goes as `<all_urls>`, which covers `*://*/*` and which extensions check for with `permissions.contains`; WebKit's `<all_urls>` reaches no file pages.
    private static func engineExtension(_ installed: InstalledPlugin) -> EngineExtension? {
        guard let packageURL = installed.packageURL else { return nil }
        let mapped = WebExtensionManifest.mappedPermissions.filter { installed.grant.permissions.contains($0.value) }.keys
        let sites = installed.grant.sites.map { $0.description == "*://*/*" ? "<all_urls>" : $0.description }
        return EngineExtension(id: WebExtensionManifest.extensionID(of: installed.id), packageURL: packageURL,
                               permissions: Set(installed.manifest.extensionPermissions).union(mapped), sites: Set(sites))
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

    /// The engine that runs the extension and has an action for the tab, which only the tab's own engine has.
    private func engine(runningActionOf id: PluginID, for tab: any EngineWebContents) -> (any EngineExtensions)? {
        let extensionID = WebExtensionManifest.extensionID(of: id)
        return EngineKind.allCases.lazy.compactMap { kind -> (any EngineExtensions)? in
            guard self.loaded[kind]?[id] != nil, let engine = self.attached?[kind], engine.action(of: extensionID, for: tab) != nil else { return nil }
            return engine
        }.first
    }

    // MARK: Windows and actions

    /// The Persona's windows and the focused one, if it is the Persona's, each time they change.
    public func setWindows(_ windows: [EngineExtensionWindow], focusedWindowID: UUID?) {
        self.windows = windows
        self.focusedWindowID = focusedWindowID
        attached?.values.forEach { $0.setWindows(windows, focusedWindowID: focusedWindowID) }
    }

    /// The actions of the enabled extensions that have one, in the order the user installed them, for the tab.
    public func actions(for tab: any EngineWebContents) -> [WebExtensionActionItem] {
        enabled.filter { $0.manifest.contributions.commands.contains { $0.id == WebExtensionManifest.actionCommand } }.map { installed in
            let action = engine(runningActionOf: installed.id, for: tab)?.action(of: WebExtensionManifest.extensionID(of: installed.id), for: tab)
            return WebExtensionActionItem(id: installed.id, name: installed.manifest.name, action: action)
        }
    }

    /// Runs the extension's action for the tab in the engine that runs the extension there. Returns false when none does, as on a tab of an engine without extensions.
    @discardableResult
    public func performAction(of id: PluginID, for tab: any EngineWebContents) -> Bool {
        guard enabled.contains(where: { $0.id == id }), let engine = engine(runningActionOf: id, for: tab) else { return false }
        engine.performAction(of: WebExtensionManifest.extensionID(of: id), for: tab)
        return true
    }

    /// Runs the action of the extension on an open tab, for its command in the palette.
    fileprivate func performAction(of id: PluginID, onTab tabID: UUID) -> Bool {
        guard let tab = host?.webContents(ofTab: tabID) else { return false }
        return performAction(of: id, for: tab)
    }

    /// The extension with the engine identifier that the calling engine loaded, while its grant has `permission`.
    private func loadedExtension(_ extensionID: String, in engine: any EngineExtensions, granted permission: PluginPermission? = nil) -> InstalledPlugin? {
        guard let kind = attached?.first(where: { $0.value === engine })?.key,
              let installed = loaded[kind]?[WebExtensionManifest.pluginID(of: extensionID)]?.installed else { return nil }
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

    public func extensions(_ extensions: any EngineExtensions, present popup: NSPopover, ofExtension id: String, for tab: (any EngineWebContents)?) -> Bool {
        host?.present(popup, for: tab) ?? false
    }

    /// Asks with a sheet for the tab. Access that reaches every website also needs Touch ID or the login password, as at install. Native messaging is never granted here.
    public func extensions(_ extensions: any EngineExtensions, extension id: String, requests access: Set<EngineExtensionAccess>, in tab: (any EngineWebContents)?,
                           completion: @escaping (Set<EngineExtensionAccess>) -> Void) {
        guard let host, let installed = loadedExtension(id, in: extensions) else { return completion([]) }
        let prompt = WebExtensionAccessPrompt(requested: access, extensionName: installed.manifest.name)
        guard !prompt.access.isEmpty else { return completion([]) }
        host.presentSheet(prompt.alert(), for: tab) { response in
            guard response == .alertFirstButtonReturn else { return completion([]) }
            Task { completion(await prompt.confirm() ? prompt.access : []) }
        }
    }

    public func extensions(_ extensions: any EngineExtensions, extension id: String, sendNativeMessage message: Data, toApplication application: String?,
                           reply: @escaping (Result<Data, any Error>) -> Void) {
        guard loadedExtension(id, in: extensions, granted: .nativeMessaging) != nil else { return reply(.failure(PluginError.permissionDenied(.nativeMessaging))) }
        nativeMessaging.send(message, to: application, from: id, reply: reply)
    }

    public func extensions(_ extensions: any EngineExtensions, extension id: String, connect port: any EngineNativeMessagingPort) throws {
        guard loadedExtension(id, in: extensions, granted: .nativeMessaging) != nil else { throw PluginError.permissionDenied(.nativeMessaging) }
        try nativeMessaging.connect(port, from: id)
    }
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
