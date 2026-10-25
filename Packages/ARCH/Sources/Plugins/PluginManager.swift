// The plugins of one Persona. The manager registers the built-in plugins, keeps which of them the user switched on or off in `plugins.json`, exposes the contributions of the enabled ones, starts a plugin's code only when one of its commands runs, one of its panels opens, or one of its page scripts sends it a value, and keeps each plugin's data in the Persona's folder and its secrets in the Keychain.
import AppKit
import ARCHEngine
import Combine

/// A plugin the manager knows, with its grant and whether it is enabled.
public struct InstalledPlugin: Identifiable, Hashable, Sendable {
    public var id: PluginID { manifest.id }
    public var manifest: PluginManifest
    public var grant: PluginGrant
    public var isEnabled: Bool
}

@MainActor
public final class PluginManager: ObservableObject {
    private let persona: PersonaID
    /// `Plugins/<persona id>/` in the app's Application Support folder, with `plugins.json` and a folder for each plugin named by its identifier.
    private let directory: URL
    /// In the order the app listed the built-in plugins.
    @Published public private(set) var plugins: [InstalledPlugin] {
        didSet { contributions = PluginContributionIndex(plugins) }
    }
    @Published public private(set) var contributions: PluginContributionIndex
    /// The badges the plugins set, by plugin and sidebar item.
    @Published private var badges: [PluginID: [String: String]] = [:]
    private let builtIns: [PluginID: any BuiltInPlugin.Type]
    /// The choices `plugins.json` keeps, in the order the user made them, including those for plugins this build does not have.
    private var choices: [PluginListFile.Choice]
    private let secretStore: any PluginSecretStore
    /// Plugins whose code has started. Each starts at its first command, panel, or page script value and runs until the user switches it off or deletes the Persona, or the app quits.
    private var running: [PluginID: RunningPlugin] = [:]
    /// The storage of each plugin, made when the plugin starts or its settings are first read. It outlives a failed activation, so the plugin's next start finds the changes that have not reached the file.
    private var storages: [PluginID: PluginStorageFile] = [:]

    /// A started plugin and its activation, which its commands, panels, and page script values wait for.
    private struct RunningPlugin {
        let plugin: any Plugin
        let activation: Task<Void, any Error>
    }

    /// `directory` is the app's Application Support folder. Built-in plugins get everything their manifests ask for. Of two built-in plugins with the same identifier, the first counts.
    public convenience init(persona: PersonaID, directory: URL, builtIns: [any BuiltInPlugin.Type]) {
        self.init(persona: persona, directory: directory, builtIns: builtIns, secretStore: PluginKeychain())
    }

    init(persona: PersonaID, directory: URL, builtIns: [any BuiltInPlugin.Type], secretStore: any PluginSecretStore) {
        self.persona = persona
        self.directory = Self.folder(of: persona, in: directory)
        self.secretStore = secretStore
        let choices = PluginFile.read(PluginListFile.self, at: self.directory.appendingPathComponent(PluginListFile.name))?.choices ?? []
        var plugins: [InstalledPlugin] = []
        var types: [PluginID: any BuiltInPlugin.Type] = [:]
        for type in builtIns where types[type.manifest.id] == nil {
            types[type.manifest.id] = type
            let choice = choices.first { $0.id == type.manifest.id.rawValue }
            plugins.append(InstalledPlugin(manifest: type.manifest, grant: PluginGrant(requestedBy: type.manifest), isEnabled: choice?.isEnabled ?? type.isOnByDefault))
        }
        self.plugins = plugins
        self.builtIns = types
        self.choices = choices
        contributions = PluginContributionIndex(plugins)
    }

    // MARK: Switching plugins on and off

    /// Records the choice in `plugins.json`. Switching a plugin off removes its contributions, so its page scripts stop at each tab's next load and their values no longer reach it, and stops its code.
    public func setEnabled(_ isEnabled: Bool, for id: PluginID) {
        guard let index = plugins.firstIndex(where: { $0.id == id }), plugins[index].isEnabled != isEnabled else { return }
        choices.removeAll { $0.id == id.rawValue }
        choices.append(PluginListFile.Choice(id: id.rawValue, isEnabled: isEnabled))
        // Choices are few and rare, so each writes the file at once.
        if let data = try? JSONEncoder().encode(PluginListFile(choices: choices)) {
            PluginFile.write(data, to: directory.appendingPathComponent(PluginListFile.name))
        }
        plugins[index].isEnabled = isEnabled
        if !isEnabled { stop(id) }
    }

    /// Drops the plugin's badges and its running instance, which deactivates once its activation ends.
    private func stop(_ id: PluginID) {
        badges[id] = nil
        guard let stopped = running.removeValue(forKey: id) else { return }
        Task {
            guard (try? await stopped.activation.value) != nil else { return }
            await stopped.plugin.deactivate()
        }
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

    /// The Persona's folder, `Plugins/<persona id>/` in `directory`, the app's Application Support folder.
    nonisolated private static func folder(of persona: PersonaID, in directory: URL) -> URL {
        directory.appendingPathComponent("Plugins", isDirectory: true).appendingPathComponent(persona.uuidString, isDirectory: true)
    }

    /// Deletes what the plugins of a deleted Persona left, before any manager of the Persona exists: their secrets in the Keychain and the Persona's folder in `directory`, the app's Application Support folder. Reports whether all of it is gone; data that was never there counts as gone.
    nonisolated public static func removeData(ofPersona persona: PersonaID, in directory: URL) -> Bool {
        removeData(ofPersona: persona, in: directory, secretStore: PluginKeychain())
    }

    nonisolated static func removeData(ofPersona persona: PersonaID, in directory: URL, secretStore: any PluginSecretStore) -> Bool {
        let secretsRemoved = (try? secretStore.removeSecrets(accountPrefix: ScopedPluginSecrets.accountPrefix(of: persona))) != nil
        let folder = folder(of: persona, in: directory)
        let folderRemoved = !FileManager.default.fileExists(atPath: folder.path) || (try? FileManager.default.removeItem(at: folder)) != nil
        return secretsRemoved && folderRemoved
    }

    // MARK: Contributions

    /// Runs a command of an enabled plugin, starting the plugin first if it has not started. The plugin receives the invocation's tab without what its grant does not cover. A command that fails, or whose plugin fails to start, beeps.
    public func run(_ command: PluginCommandRef, _ invocation: PluginInvocation) async {
        guard let installed = enabledPlugin(command.plugin), installed.manifest.contributions.commands.contains(where: { $0.id == command.command }),
              let type = builtIns[installed.id] else { return }
        var redacted = invocation
        redacted.tab = invocation.tab?.redacted(for: installed.grant)
        do {
            try await start(installed, as: type)?.run(command.command, redacted)
        } catch {
            NSSound.beep()
        }
    }

    /// The panel of a sidebar item whose action is `.panel`, from its plugin, which starts first if it has not started. Nil, with a beep, when the plugin offers no panel for the item or fails to start.
    public func panel(for item: Attributed<PluginSidebarItem>) async -> NSViewController? {
        guard item.item.action == .panel, let installed = enabledPlugin(item.plugin),
              installed.manifest.contributions.sidebarItems.contains(item.item), let type = builtIns[installed.id] else { return nil }
        if let panel = try? await start(installed, as: type)?.panel(for: item.item.id) { return panel }
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

    /// Whether a page script of the enabled plugin runs in the main frame at `url`: one of the script's patterns and one of the plugin's granted sites cover the address.
    public func pageScriptsCover(_ url: URL, of id: PluginID) -> Bool {
        guard let installed = enabledPlugin(id), installed.grant.covers(url) else { return false }
        return installed.manifest.contributions.pageScripts.contains { script in script.matches.contains { $0.matches(url) } }
    }

    /// Passes a value that a page script in `tab` sent to its plugin, starting the plugin first if it has not started. The value reaches the plugin only while the plugin is enabled and its granted sites cover the sending frame's document, and the plugin receives the tab without what its grant does not cover. Returns the plugin's reply as JSON text, or nil when there is none or the plugin fails.
    public func receive(_ message: EnginePageScriptMessage, from tab: PluginTab) async -> String? {
        guard let installed = plugins.first(where: { $0.id.pageScriptWorld == message.world }), installed.isEnabled,
              let frameURL = message.frameURL, installed.grant.covers(frameURL), let type = builtIns[installed.id],
              let body = try? JSONDecoder().decode(PluginValue.self, from: Data(message.json.utf8)) else { return nil }
        let page = PluginPageMessage(tab: tab.redacted(for: installed.grant), frameURL: frameURL, isMainFrame: message.isMainFrame, body: body)
        do {
            guard let reply = try await start(installed, as: type)?.receive(page) else { return nil }
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

    private func enabledPlugin(_ id: PluginID) -> InstalledPlugin? {
        plugins.first { $0.id == id && $0.isEnabled }
    }

    /// The running plugin, started first if needed, or nil when the user switched it off while it activated. Commands, panels, and page script values that arrive while the plugin activates wait for the same activation. A failed activation leaves the plugin stopped, so its next use starts it again.
    private func start(_ installed: InstalledPlugin, as type: any BuiltInPlugin.Type) async throws -> (any Plugin)? {
        let started: RunningPlugin
        if let existing = running[installed.id] {
            started = existing
        } else {
            let plugin = type.init()
            let context = makeContext(for: installed)
            started = RunningPlugin(plugin: plugin, activation: Task { try await plugin.activate(in: context) })
            running[installed.id] = started
        }
        do {
            try await started.activation.value
        } catch {
            if running[installed.id]?.plugin === started.plugin { running[installed.id] = nil }
            throw error
        }
        return running[installed.id]?.plugin === started.plugin ? started.plugin : nil
    }

    func makeContext(for installed: InstalledPlugin) -> ScopedPluginContext {
        ScopedPluginContext(manager: self, pluginID: installed.id, personaID: persona, grant: installed.grant, storage: storage(for: installed.id), secrets: secrets(for: installed.id))
    }

    /// `<plugin id>/storage.json` in the Persona's folder.
    private func storage(for id: PluginID) -> PluginStorageFile {
        if let storage = storages[id] { return storage }
        let storage = PluginStorageFile(fileURL: directory.appendingPathComponent(id.rawValue, isDirectory: true).appendingPathComponent("storage.json"))
        storages[id] = storage
        return storage
    }

    private func secrets(for id: PluginID) -> ScopedPluginSecrets {
        ScopedPluginSecrets(store: secretStore, pluginID: id, personaID: persona)
    }
}

/// `plugins.json` in the Persona's folder: whether each plugin the user switched on or off is enabled. A plugin without a choice follows `BuiltInPlugin.isOnByDefault`.
private struct PluginListFile: Codable {
    static let name = "plugins.json"

    struct Choice: Codable {
        /// The plugin's identifier as `PluginID` writes it.
        var id: String
        var isEnabled: Bool
    }

    var choices: [Choice]
}

/// The context the manager gives each plugin it starts.
@MainActor
final class ScopedPluginContext: PluginContext {
    let pluginID: PluginID
    let personaID: PersonaID
    let grant: PluginGrant
    let storage: any PluginStorage
    let secrets: any PluginSecrets
    private weak var manager: PluginManager?

    init(manager: PluginManager, pluginID: PluginID, personaID: PersonaID, grant: PluginGrant, storage: any PluginStorage, secrets: any PluginSecrets) {
        self.manager = manager
        self.pluginID = pluginID
        self.personaID = personaID
        self.grant = grant
        self.storage = storage
        self.secrets = secrets
    }

    func setting(_ key: String) -> PluginValue? {
        manager?.setting(key, of: pluginID)
    }

    func setBadge(_ text: String?, onSidebarItem id: String) {
        manager?.setBadge(text, onSidebarItem: id, of: pluginID)
    }

    func copyToClipboard(_ text: String) throws {
        try require(.clipboard)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func require(_ permission: PluginPermission) throws {
        guard grant.permissions.contains(permission) else { throw PluginError.permissionDenied(permission) }
    }
}
