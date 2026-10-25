// Plugin data that earlier builds kept under identifiers and Keychain services that start with `local.arch.`, moved once at launch to those under `xyz.taeyoon.arch.`: the plugin folders, the `plugins.json` entries, and the package manifests that name a plugin identifier, the Keychain items of plugin secrets, and the shortcuts the user chose for plugin commands.
import Foundation

/// Gives the plugins whose identifiers start with `local.arch.browser.`, as built-in plugins' did, or with `local.arch.generated.`, as those of plugins that AI wrote did, the identifiers that replace them, with their folders, `plugins.json` entries, manifests, secrets, and shortcuts, and moves every plugin secret from the previous service prefix to `PluginKeychain.servicePrefix`. An item moves only while its new name is free, and the previous item goes only once the new one exists, so a run that stopped partway finishes at the next launch and a finished run finds nothing to do. Staging refuses packages with the previous identifiers, so they do not come back, and no build saves secrets under the previous service prefix, so once none is left there, later launches skip the Keychain.
public struct PluginIdentifierMigration {
    /// Each previous identifier prefix with the prefix that replaces it.
    static let renamedPrefixes: [(previous: String, current: String)] = [
        ("local.arch.browser.", "xyz.taeyoon.arch."),
        ("local.arch.generated.", PluginComposer.identifierPrefix),
    ]
    /// The preference under which `ShortcutSettings` keeps the user's shortcuts, by command identifiers such as `runCommand:#<plugin id>/<command>` for an item of the Plugins menu.
    static let shortcutsKey = "ARCHShortcuts"
    /// The preference that records that no plugin secret is left under the previous service prefix.
    static let secretsMovedKey = "ARCHPluginSecretsMoved"

    /// The app's Application Support folder, whose `Plugins/` holds a folder for each Persona.
    var directory: URL
    /// The start of the services of plugin secrets in earlier builds, which the plugin identifier follows.
    var previousServicePrefix: String
    var servicePrefix: String
    /// The defaults that hold the user's shortcuts and `secretsMovedKey`.
    var defaults: UserDefaults

    /// The app calls it after `BundleIdentifierMigration`, which moves the preferences it reads, and before any `PluginManager` exists.
    public static func runAtLaunch() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arch")
        let migration = PluginIdentifierMigration(directory: directory, previousServicePrefix: PluginKeychain.previousServicePrefix, servicePrefix: PluginKeychain.servicePrefix,
                                                  defaults: .standard)
        migration.moveFiles()
        migration.moveSecrets()
        migration.moveShortcuts()
    }

    /// The identifier that replaces `id`, or nil for one that stays.
    static func renamed(_ id: String) -> String? {
        renamedPrefixes.first { id.hasPrefix($0.previous) }.map { $0.current + id.dropFirst($0.previous.count) }
    }

    /// In each Persona's folder, renames each plugin folder named by a previous identifier while no folder has the new one, after giving the identifier in its package's `plugin.json` the new name, then renames the identifiers in `plugins.json`. A folder whose `plugin.json` could not take the new name keeps its own until a later launch, since the manager reads a plugin only from a package whose manifest names the folder's identifier.
    func moveFiles() {
        let manager = FileManager.default
        let plugins = directory.appendingPathComponent("Plugins", isDirectory: true)
        for persona in (try? manager.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? [] {
            for folder in (try? manager.contentsOfDirectory(at: persona, includingPropertiesForKeys: nil)) ?? [] {
                let previous = folder.lastPathComponent
                guard let id = Self.renamed(previous) else { continue }
                let destination = persona.appendingPathComponent(id, isDirectory: true)
                guard !manager.fileExists(atPath: destination.path),
                      Self.renameManifest(at: folder.appendingPathComponent("package/\(ScriptManifest.fileName)"), from: previous, to: id) else { continue }
                try? manager.moveItem(at: folder, to: destination)
            }
            Self.renameEntries(at: persona.appendingPathComponent(PluginListFile.name))
        }
    }

    /// Writes `id` in place of `previous` in a script plugin's `plugin.json`, formatted as `PluginComposer` writes it, and reports whether the folder may take the new name: true when the file now names `id`, is missing, as in a built-in plugin's folder, which holds only its storage, or does not name `previous`, as after a run that wrote it but did not move the folder, and false when it exists but could not be read or rewritten.
    private static func renameManifest(at url: URL, from previous: String, to id: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return !FileManager.default.fileExists(atPath: url.path) }
        guard case var .object(fields)? = try? JSONDecoder().decode(PluginValue.self, from: data),
              case let .string(text)? = fields["id"], PluginID(rawValue: text)?.rawValue == previous else { return true }
        fields["id"] = .string(id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let renamed = try? encoder.encode(PluginValue.object(fields)) else { return false }
        return (try? renamed.write(to: url, options: .atomic)) != nil
    }

    /// Renames the identifiers of the choices and installs in `plugins.json`, entries this build cannot read among them. An entry whose new identifier another entry of its list has goes, as the newer entry wins. A file that does not decode stays for the manager, which keeps it aside.
    private static func renameEntries(at url: URL) {
        guard let data = try? Data(contentsOf: url), var list = try? JSONDecoder().decode(PluginListFile.self, from: data) else { return }
        let choices = renaming(list.choices, id: { $0.id }) { choice, id in
            var choice = choice
            choice.id = id
            return choice
        }
        let installs = list.installed.flatMap { renaming($0, id: \.id) { $0.renamed(to: $1) } }
        guard choices != nil || installs != nil else { return }
        list.choices = choices ?? list.choices
        list.installed = installs ?? list.installed
        guard let renamed = try? JSONEncoder().encode(list) else { return }
        PluginFile.write(renamed, to: url)
    }

    /// The entries with their previous identifiers renamed, less those whose new identifier another entry has, or nil when no entry has a previous identifier.
    private static func renaming<Entry>(_ entries: [Entry], id: (Entry) -> String?, rename: (Entry, String) -> Entry) -> [Entry]? {
        let ids = Set(entries.compactMap(id))
        var changed = false
        let renamed = entries.compactMap { entry -> Entry? in
            guard let previous = id(entry), let current = Self.renamed(previous) else { return entry }
            changed = true
            return ids.contains(current) ? nil : rename(entry, current)
        }
        return changed ? renamed : nil
    }

    /// Adds each plugin secret under `previousServicePrefix` to its plugin's service under `servicePrefix`, with the plugin's new identifier, unless that service has the account already, then deletes the previous item. Reading a secret shows the login keychain prompt only when the build that saved it had another code signature, as an ad hoc signed build has after each rebuild; an item whose secret cannot be read stays for the next launch. Once every item has moved, `secretsMovedKey` records it, so that later launches do not list the Keychain's items again.
    func moveSecrets() {
        guard !defaults.bool(forKey: Self.secretsMovedKey) else { return }
        let keychain = PluginKeychain()
        guard let items = try? keychain.items(withServicePrefix: previousServicePrefix) else { return }
        var isFinished = true
        for item in items {
            let service = Self.movedService(item.service, from: previousServicePrefix, to: servicePrefix)
            do {
                if try !keychain.containsSecret(service: service, account: item.account) {
                    guard let secret = try keychain.secret(service: item.service, account: item.account) else { continue }
                    try keychain.setSecret(secret, service: service, account: item.account)
                }
                try keychain.setSecret(nil, service: item.service, account: item.account)
            } catch {
                isFinished = false
            }
        }
        if isFinished { defaults.set(true, forKey: Self.secretsMovedKey) }
    }

    /// The service under `prefix` that `moveSecrets` moves the items of `service`, a service under `previousPrefix`, to: the one of its plugin's new identifier.
    static func movedService(_ service: String, from previousPrefix: String, to prefix: String) -> String {
        let id = String(service.dropFirst(previousPrefix.count))
        return prefix + (renamed(id) ?? id)
    }

    /// Renames the plugin identifier in each command identifier of the user's shortcuts. A shortcut that the new command identifier has already wins.
    func moveShortcuts() {
        guard var shortcuts = defaults.dictionary(forKey: Self.shortcutsKey) else { return }
        var changed = false
        for command in shortcuts.keys.sorted() {
            guard let renamed = Self.renamedCommand(command), let shortcut = shortcuts.removeValue(forKey: command) else { continue }
            if shortcuts[renamed] == nil { shortcuts[renamed] = shortcut }
            changed = true
        }
        if changed { defaults.set(shortcuts, forKey: Self.shortcutsKey) }
    }

    /// The command identifier with the previous plugin identifier after its `#` renamed, or nil when it names none.
    static func renamedCommand(_ command: String) -> String? {
        for prefix in renamedPrefixes {
            if let range = command.range(of: "#" + prefix.previous) { return command.replacingCharacters(in: range, with: "#" + prefix.current) }
        }
        return nil
    }
}

extension PluginListFile.InstallEntry {
    /// The entry with the identifier `id`; one without an identifier stays as it is.
    func renamed(to id: String) -> Self {
        switch self {
        case var .readable(install):
            install.id = id
            return .readable(install)
        case .unreadable(.object(var fields)):
            fields["id"] = .string(id)
            return .unreadable(.object(fields))
        case .unreadable:
            return self
        }
    }
}
