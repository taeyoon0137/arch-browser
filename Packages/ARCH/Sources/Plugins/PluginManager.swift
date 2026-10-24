// The plugins of one Persona. The manager registers the built-in plugins, exposes the contributions of the enabled ones, starts a plugin's code only when one of its commands runs, and keeps each plugin's data in the Persona's folder.
import AppKit

/// A plugin the manager knows, with its grant and whether it is enabled.
public struct InstalledPlugin: Identifiable, Hashable, Sendable {
    public var id: PluginID { manifest.id }
    public var manifest: PluginManifest
    public var grant: PluginGrant
    public var isEnabled: Bool
}

@MainActor
public final class PluginManager {
    private let persona: PersonaID
    /// `Plugins/<persona id>/` in the app's Application Support folder, with a folder for each plugin named by its identifier.
    private let directory: URL
    /// In the order the app listed the built-in plugins.
    public let plugins: [InstalledPlugin]
    public let contributions: PluginContributionIndex
    private let builtIns: [PluginID: any BuiltInPlugin.Type]
    /// Plugins whose code has started. Each starts at its first command and runs until the app quits.
    private var running: [PluginID: RunningPlugin] = [:]
    /// The storage of each plugin that has started. It outlives a failed activation, so the plugin's next start finds the changes that have not reached the file.
    private var storages: [PluginID: PluginStorageFile] = [:]

    /// A started plugin and its activation, which its commands wait for.
    private struct RunningPlugin {
        let plugin: any Plugin
        let activation: Task<Void, any Error>
    }

    /// `directory` is the app's Application Support folder. Built-in plugins get everything their manifests ask for. Of two built-in plugins with the same identifier, the first counts.
    public init(persona: PersonaID, directory: URL, builtIns: [any BuiltInPlugin.Type]) {
        self.persona = persona
        self.directory = directory.appendingPathComponent("Plugins", isDirectory: true).appendingPathComponent(persona.uuidString, isDirectory: true)
        var plugins: [InstalledPlugin] = []
        var types: [PluginID: any BuiltInPlugin.Type] = [:]
        for type in builtIns where types[type.manifest.id] == nil {
            types[type.manifest.id] = type
            plugins.append(InstalledPlugin(manifest: type.manifest, grant: PluginGrant(requestedBy: type.manifest), isEnabled: type.isOnByDefault))
        }
        self.plugins = plugins
        self.builtIns = types
        contributions = PluginContributionIndex(plugins)
    }

    /// Runs a command of an enabled plugin, starting the plugin first if it has not started. The plugin receives the invocation without what its grant does not cover. A command that fails, or whose plugin fails to start, beeps.
    public func run(_ command: PluginCommandRef, _ invocation: PluginInvocation) async {
        guard let installed = plugins.first(where: { $0.id == command.plugin }), installed.isEnabled,
              installed.manifest.contributions.commands.contains(where: { $0.id == command.command }),
              let type = builtIns[installed.id] else { return }
        do {
            let plugin = try await start(installed, as: type)
            try await plugin.run(command.command, PluginInvocation(tab: invocation.tab?.redacted(for: installed.grant)))
        } catch {
            NSSound.beep()
        }
    }

    /// Commands that arrive while the plugin activates wait for the same activation. A failed activation leaves the plugin stopped, so its next command starts it again.
    private func start(_ installed: InstalledPlugin, as type: any BuiltInPlugin.Type) async throws -> any Plugin {
        let started: RunningPlugin
        if let existing = running[installed.id] {
            started = existing
        } else {
            let plugin = type.init()
            let context = ScopedPluginContext(pluginID: installed.id, personaID: persona, grant: installed.grant, storage: storage(for: installed.id))
            started = RunningPlugin(plugin: plugin, activation: Task { try await plugin.activate(in: context) })
            running[installed.id] = started
        }
        do {
            try await started.activation.value
        } catch {
            if running[installed.id]?.plugin === started.plugin { running[installed.id] = nil }
            throw error
        }
        return started.plugin
    }

    /// `<plugin id>/storage.json` in the Persona's folder.
    private func storage(for id: PluginID) -> PluginStorageFile {
        if let storage = storages[id] { return storage }
        let storage = PluginStorageFile(fileURL: directory.appendingPathComponent(id.rawValue, isDirectory: true).appendingPathComponent("storage.json"))
        storages[id] = storage
        return storage
    }
}

/// The context the manager gives each plugin it starts.
@MainActor
final class ScopedPluginContext: PluginContext {
    let pluginID: PluginID
    let personaID: PersonaID
    let grant: PluginGrant
    let storage: any PluginStorage

    init(pluginID: PluginID, personaID: PersonaID, grant: PluginGrant, storage: any PluginStorage) {
        self.pluginID = pluginID
        self.personaID = personaID
        self.grant = grant
        self.storage = storage
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
