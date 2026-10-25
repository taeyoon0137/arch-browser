// The web extensions of one Persona as a kind of plugin. The runtime reads their packages, loads each enabled extension with what the user granted it into the Persona's profiles in the engines that run extensions, and does for those engines what the app does for extensions: it shows their popups, asks the user about access they request while they run, and relays their native messages. The plugin list stays engine-independent, so that every engine that runs extensions runs the same installs.
import AppKit
import ARCHEngine
import Plugins

/// What `Browsing` provides so that a Persona's web extensions reach its engines, tabs, and windows.
@MainActor
public protocol WebExtensionHost: AnyObject {
    /// The Persona's profiles in the engines that run web extensions, which the host starts if they have not started.
    func extensionEngines(in persona: PersonaID) -> [any EngineExtensions]
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
    /// Nil while the tab's engine does not run the extension, as on a Chromium tab, or before the extension has loaded.
    public let action: EngineExtensionAction?
}

@MainActor
public final class WebExtensionRuntime: ObservableObject, PluginRuntime {
    public nonisolated let kind = PluginKind.webExtension
    public nonisolated let manifestFileName = WebExtensionManifest.fileName
    public var onFailure: ((PluginID, String) -> Void)?
    private let persona: PersonaID
    private weak var host: (any WebExtensionHost)?
    private let nativeMessaging: NativeMessaging
    /// The Persona's profiles in the engines that run extensions, from the first extension that loads or goes.
    private var engines: [any EngineExtensions]?
    /// The enabled extensions, in the order the user installed them, as the manager last listed them.
    private var enabled: [InstalledPlugin] = []
    /// The extensions the engines run, with the install each loaded.
    private var loaded: [PluginID: InstalledPlugin] = [:]
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

    /// WebKit runs web extensions from macOS 15.4; Chromium does not run them yet.
    public var unavailability: String? {
        guard #available(macOS 15.4, *) else { return "Web extensions need macOS 15.4 or later." }
        return nil
    }

    public func run(_ enabled: [InstalledPlugin]) {
        self.enabled = enabled
        changeEngines { await $0.loadEnabledExtensions() }
    }

    public func makePlugin(_ installed: InstalledPlugin) -> any Plugin {
        WebExtensionPlugin(runtime: self, id: installed.id)
    }

    /// Takes the extension out of the engines and deletes its storage there.
    public func remove(_ installed: InstalledPlugin) {
        enabled.removeAll { $0.id == installed.id }
        changeEngines { runtime in
            let id = WebExtensionManifest.extensionID(of: installed.id)
            let engines = runtime.attachedEngines()
            engines.forEach { $0.unload(id) }
            runtime.loaded[installed.id] = nil
            for engine in engines { await engine.removeData(of: id) }
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

    /// Unloads the extensions that are no longer enabled or whose install changed, then loads the enabled ones that are not loaded. An extension that an engine cannot start goes out of every engine, and the manager switches it off with why.
    private func loadEnabledExtensions() async {
        guard !enabled.isEmpty || !loaded.isEmpty else { return }
        let engines = attachedEngines()
        for (id, installed) in loaded where !enabled.contains(installed) {
            engines.forEach { $0.unload(WebExtensionManifest.extensionID(of: id)) }
            loaded[id] = nil
        }
        for installed in enabled where loaded[installed.id] == nil {
            guard let engineExtension = Self.engineExtension(installed) else { continue }
            do {
                for engine in engines { try await engine.load(engineExtension) }
                loaded[installed.id] = installed
            } catch {
                engines.forEach { $0.unload(engineExtension.id) }
                onFailure?(installed.id, "Arch could not start the extension: \(error.localizedDescription)")
            }
        }
        objectWillChange.send()
    }

    /// The extension as the engines load it: its package, the API permissions its grant covers with those that come with the install, and its granted sites. Every web page, which Arch's patterns write as `*://*/*`, goes as `<all_urls>`, which covers `*://*/*` and which extensions check for with `permissions.contains`; WebKit's `<all_urls>` reaches no file pages.
    private static func engineExtension(_ installed: InstalledPlugin) -> EngineExtension? {
        guard let packageURL = installed.packageURL else { return nil }
        let mapped = WebExtensionManifest.mappedPermissions.filter { installed.grant.permissions.contains($0.value) }.keys
        let sites = installed.grant.sites.map { $0.description == "*://*/*" ? "<all_urls>" : $0.description }
        return EngineExtension(id: WebExtensionManifest.extensionID(of: installed.id), packageURL: packageURL,
                               permissions: Set(installed.manifest.extensionPermissions).union(mapped), sites: Set(sites))
    }

    /// The Persona's engines that run extensions, attached at first use with the runtime as their delegate and the windows the host reported.
    private func attachedEngines() -> [any EngineExtensions] {
        if let engines { return engines }
        let attached = host?.extensionEngines(in: persona) ?? []
        for engine in attached {
            engine.delegate = self
            engine.setWindows(windows, focusedWindowID: focusedWindowID)
        }
        engines = attached
        return attached
    }

    // MARK: Windows and actions

    /// The Persona's windows and the focused one, if it is the Persona's, each time they change.
    public func setWindows(_ windows: [EngineExtensionWindow], focusedWindowID: UUID?) {
        self.windows = windows
        self.focusedWindowID = focusedWindowID
        engines?.forEach { $0.setWindows(windows, focusedWindowID: focusedWindowID) }
    }

    /// The actions of the enabled extensions that have one, in the order the user installed them, for the tab.
    public func actions(for tab: any EngineWebContents) -> [WebExtensionActionItem] {
        enabled.filter { $0.manifest.contributions.commands.contains { $0.id == WebExtensionManifest.actionCommand } }.map { installed in
            let id = WebExtensionManifest.extensionID(of: installed.id)
            let action = loaded[installed.id] == nil ? nil : (engines ?? []).lazy.compactMap { $0.action(of: id, for: tab) }.first
            return WebExtensionActionItem(id: installed.id, name: installed.manifest.name, action: action)
        }
    }

    /// Runs the extension's action for the tab in the engine that runs the extension there. Returns false when none does, as on a tab of an engine without extensions.
    @discardableResult
    public func performAction(of id: PluginID, for tab: any EngineWebContents) -> Bool {
        let extensionID = WebExtensionManifest.extensionID(of: id)
        guard enabled.contains(where: { $0.id == id }), loaded[id] != nil,
              let engine = engines?.first(where: { $0.action(of: extensionID, for: tab) != nil }) else { return false }
        engine.performAction(of: extensionID, for: tab)
        return true
    }

    /// Runs the action of the extension on an open tab, for its command in the palette.
    fileprivate func performAction(of id: PluginID, onTab tabID: UUID) -> Bool {
        guard let tab = host?.webContents(ofTab: tabID) else { return false }
        return performAction(of: id, for: tab)
    }

    /// The loaded extension with the engine identifier, while its grant has `permission`.
    private func loadedExtension(_ extensionID: String, granted permission: PluginPermission? = nil) -> InstalledPlugin? {
        guard let installed = loaded[WebExtensionManifest.pluginID(of: extensionID)] else { return nil }
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
        guard let host, let installed = loadedExtension(id) else { return completion([]) }
        let prompt = WebExtensionAccessPrompt(requested: access, extensionName: installed.manifest.name)
        guard !prompt.access.isEmpty else { return completion([]) }
        host.presentSheet(prompt.alert(), for: tab) { response in
            guard response == .alertFirstButtonReturn else { return completion([]) }
            Task { completion(await prompt.confirm() ? prompt.access : []) }
        }
    }

    public func extensions(_ extensions: any EngineExtensions, extension id: String, sendNativeMessage message: Data, toApplication application: String?,
                           reply: @escaping (Result<Data, any Error>) -> Void) {
        guard loadedExtension(id, granted: .nativeMessaging) != nil else { return reply(.failure(PluginError.permissionDenied(.nativeMessaging))) }
        nativeMessaging.send(message, to: application, from: id, reply: reply)
    }

    public func extensions(_ extensions: any EngineExtensions, extension id: String, connect port: any EngineNativeMessagingPort) throws {
        guard loadedExtension(id, granted: .nativeMessaging) != nil else { throw PluginError.permissionDenied(.nativeMessaging) }
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
