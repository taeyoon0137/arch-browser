// Installs and updates extensions from the Web Store (`docs/web-store.md`, Install flow and Updates): asks the store for an extension's current package, downloads it into the Persona's staging folder unless the Persona has that version installed from the store, and stages it with the origin `webStore`, which checks the store's signature and the identifier, for the same review as any package. It also asks the store about a Persona's store installs when Settings ▸ Plugins asks, keeps the newer versions it finds for the run, and stages one of them as an update of its plugin. The session owns one installer for every Persona.
import Combine
import Foundation
import Plugins

/// The last update check of a Persona's store installs in this run, as Settings ▸ Plugins shows it.
public enum WebStoreUpdateCheck: Equatable, Sendable {
    /// The store has not answered yet.
    case checking
    /// The store answered at the date.
    case checked(Date)
    /// The check failed with the message.
    case failed(String)
}

/// Stages Web Store extensions and tracks available updates for each Persona during this run.
@MainActor
public final class WebStoreInstaller: ObservableObject {
    private let client: WebStoreClient
    /// The newer versions that the last check of each Persona found, by the plugin they update. They last for the run, and an update keeps its entry after it installs, which `update(of:in:)` then no longer offers.
    @Published public private(set) var updates: [PersonaID: [PluginID: WebStoreRelease]] = [:]
    /// Each Persona's last update check in this run. A Persona without one has not been checked.
    @Published public private(set) var updateChecks: [PersonaID: WebStoreUpdateCheck] = [:]

    nonisolated public init(client: WebStoreClient) {
        self.client = client
    }

    /// The plugin among `plugins` that holds the extension `id`, from the Web Store or not, a version of a pair among them, or nil, also for text that is not an identifier. A store page's row in the site settings popover names it as installed.
    nonisolated public static func installedPlugin(of id: String, among plugins: [InstalledPlugin]) -> InstalledPlugin? {
        guard let id = WebStore.identifier(id) else { return nil }
        let pluginID = WebExtensionManifest.pluginID(of: id)
        return plugins.first { $0.kind == .webExtension && $0.manifest.id == pluginID }
    }

    /// Whether any of the plugins came from the Web Store, which Check for Updates covers.
    nonisolated public static func hasStoreInstalls(among plugins: [InstalledPlugin]) -> Bool {
        !storeInstalls(among: plugins).isEmpty
    }

    // MARK: Installing

    /// Downloads the current package of the extension `id`, an identifier as `WebStore.extensionID(from:)` reads it, and stages it in the Persona of `plugins` with the origin `webStore(id)`, for the review. Throws `WebStoreError` when the store offers no package, when the Persona has the store's current version installed from the store, which downloads nothing, and when the download fails its checks; `PluginError` when staging refuses the package, and `PluginError.closed`, without asking or downloading, once the session has closed `plugins` as it deleted the Persona; and the system's error when the network fails. Cancelling the task throws `CancellationError` at whatever step it comes: it stops the request or the download, and a package that staging finished meanwhile is discarded. The downloaded file is deleted once the package is staged or refused, and on every failure.
    public func stage(_ id: String, in plugins: PluginManager) async throws -> PluginPackage {
        try await staged(in: plugins) {
            guard let id = WebStore.identifier(id) else { throw WebStoreError.unknownExtension(id) }
            guard !plugins.isClosed else { throw PluginError.closed }
            let release = try await currentRelease(of: id)
            if let installed = plugins.plugins.first(where: { $0.origin == .webStore(id) && $0.manifest.version == release.version }) {
                throw WebStoreError.alreadyInstalled(name: installed.manifest.name, version: release.version)
            }
            return try await downloadAndStage(release, in: plugins)
        }
    }

    /// Runs the steps of a staging, ending a cancelled task with `CancellationError`, also when a step ended in another way, as a cancelled request does with the system's error, or when staging finished meanwhile, whose package is discarded since staging does not stop for a cancellation.
    private func staged(in plugins: PluginManager, _ steps: () async throws -> PluginPackage) async throws -> PluginPackage {
        do {
            let package = try await steps()
            guard !Task.isCancelled else {
                plugins.discard(package)
                throw CancellationError()
            }
            return package
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    /// Downloads the release's package into the staging folder and stages it with the origin `webStore`, unless the task was cancelled, or the Persona deleted, while the store answered.
    private func downloadAndStage(_ release: WebStoreRelease, in plugins: PluginManager) async throws -> PluginPackage {
        try Task.checkCancellation()
        guard !plugins.isClosed else { throw PluginError.closed }
        // `Staging/` is cleared at launch, so a download that a quit cuts short leaves nothing behind.
        try FileManager.default.createDirectory(at: plugins.stagingDirectory, withIntermediateDirectories: true)
        let file = plugins.stagingDirectory.appendingPathComponent("\(UUID().uuidString).crx")
        defer { try? FileManager.default.removeItem(at: file) }
        try await client.download(release, to: file)
        try Task.checkCancellation()
        return try await plugins.stage(file, origin: .webStore(release.id))
    }

    /// The store's current release of the extension, asked with the version `0.0.0.0`.
    private func currentRelease(of id: String) async throws -> WebStoreRelease {
        switch try await client.releases(of: [(id, nil)])[id] {
        case let .release(release): return release
        case .unknown: throw WebStoreError.unknownExtension(id)
        case .noUpdate: throw WebStoreError.notOffered(id, status: "noupdate")
        case let .refused(status): throw WebStoreError.notOffered(id, status: status)
        case nil: throw WebStoreError.unreadableAnswer
        }
    }

    // MARK: Updates

    /// Asks the store about the store installs of the Persona of `plugins`, each with its installed version, at most 25 to a request, and keeps the versions that are newer, replacing the Persona's earlier results; file installs are not asked about, and without a store install nothing is asked or recorded. `onlyOncePerRun` skips a Persona already checked in the run, as Settings ▸ Plugins does when it shows the Persona, and a check under way for the Persona is never joined by another. `updateChecks` records the check, and its failure with the system's or `WebStoreError`'s message, which the call also throws; a failure keeps the versions found earlier. Throws `PluginError.closed` for a Persona that the session deleted, also during the check, and records nothing for it; a cancelled check throws `CancellationError` and leaves the Persona's last check as it was.
    public func checkForUpdates(in plugins: PluginManager, onlyOncePerRun: Bool) async throws {
        let persona = plugins.persona
        let previous = updateChecks[persona]
        guard previous != .checking, !(onlyOncePerRun && previous != nil) else { return }
        guard !plugins.isClosed else { throw PluginError.closed }
        let installs = Self.storeInstalls(among: plugins.plugins)
        guard !installs.isEmpty else { return }
        updateChecks[persona] = .checking
        do {
            let answers = try await client.releases(of: Self.queries(for: installs))
            guard !plugins.isClosed else { throw PluginError.closed }
            var found: [PluginID: WebStoreRelease] = [:]
            for install in installs {
                guard case let .release(release)? = answers[install.id], Self.version(release.version, isNewerThan: install.version) else { continue }
                found[install.plugin] = release
            }
            updates[persona] = found
            updateChecks[persona] = .checked(Date())
        } catch {
            if plugins.isClosed {
                forget(persona)
                throw PluginError.closed
            }
            if Task.isCancelled {
                updateChecks[persona] = previous
                throw CancellationError()
            }
            updateChecks[persona] = .failed(error.localizedDescription)
            throw error
        }
    }

    /// The newer version that the Persona's last check found for the plugin, while the plugin is installed from the store at an older version; nil otherwise, also once the update has installed.
    public func update(of plugin: InstalledPlugin, in plugins: PluginManager) -> WebStoreRelease? {
        guard case let .webStore(id) = plugin.origin, let release = updates[plugins.persona]?[plugin.id], release.id == id,
              Self.version(release.version, isNewerThan: plugin.manifest.version) else { return nil }
        return release
    }

    /// Review Update…: downloads the newer version that the last check found for the plugin, as `stage(_:in:)` downloads a package, and stages it as an update of that plugin (`PluginPackage.updates`) while the package has the plugin's identifier, also where two versions of a pair share it and the rule of `PluginManager` would send it to the other one. Throws `WebStoreError.alreadyInstalled` when no newer version is known, and otherwise as `stage(_:in:)`, cancellation among it; asks the store nothing.
    public func stageUpdate(of plugin: PluginID, in plugins: PluginManager) async throws -> PluginPackage {
        try await staged(in: plugins) {
            guard !plugins.isClosed else { throw PluginError.closed }
            guard let installed = plugins.plugins.first(where: { $0.id == plugin }), case .webStore = installed.origin else {
                throw PluginError.invalidPackage("Only an extension installed from the Web Store updates from it.")
            }
            guard let release = update(of: installed, in: plugins) else {
                throw WebStoreError.alreadyInstalled(name: installed.manifest.name, version: installed.manifest.version)
            }
            var package = try await downloadAndStage(release, in: plugins)
            if package.manifest.id == installed.manifest.id { package.updates = plugin }
            return package
        }
    }

    /// Drops the Persona's update results and check, as the session deletes the Persona.
    public func forget(_ persona: PersonaID) {
        updates[persona] = nil
        updateChecks[persona] = nil
    }

    /// The plugins installed from the store, each with the identifier it was installed under, which its package names, and its installed version.
    nonisolated private static func storeInstalls(among plugins: [InstalledPlugin]) -> [(plugin: PluginID, id: String, version: String)] {
        plugins.compactMap { plugin in
            guard case let .webStore(id) = plugin.origin else { return nil }
            return (plugin.id, id, plugin.manifest.version)
        }
    }

    /// One query for each identifier, in the order of the installs, with the oldest version installed under it, so that the store offers a release when any of them is older.
    nonisolated private static func queries(for installs: [(plugin: PluginID, id: String, version: String)]) -> [(id: String, version: String?)] {
        var queries: [(id: String, version: String?)] = []
        for install in installs {
            if let index = queries.firstIndex(where: { $0.id == install.id }) {
                if Self.version(queries[index].version ?? "", isNewerThan: install.version) { queries[index].version = install.version }
            } else {
                queries.append((install.id, install.version))
            }
        }
        return queries
    }

    /// Whether `version` comes after `installed` in Chromium's version order: one to four dot-separated numbers, compared as numbers, where a missing number counts as 0, so 1.10 comes after 1.9 and 1.0 equals 1. False when either is not such a version.
    nonisolated static func version(_ version: String, isNewerThan installed: String) -> Bool {
        guard let new = versionNumbers(version), let old = versionNumbers(installed) else { return false }
        return old.lexicographicallyPrecedes(new)
    }

    /// The four numbers of a version, the missing ones as 0, or nil for text that is not one to four dot-separated numbers below 2³².
    nonisolated private static func versionNumbers(_ version: String) -> [UInt32]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [UInt32] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }), let number = UInt32(part) else { return nil }
            numbers.append(number)
        }
        return numbers + Array(repeating: 0, count: 4 - numbers.count)
    }
}
