// Installs extensions from the Web Store (`docs/web-store.md`, Install flow): asks the store for an extension's current package, downloads it into the Persona's staging folder unless the Persona has that version installed from the store, and stages it with the origin `webStore`, which checks the store's signature and the identifier, for the same review as any package. The session owns one installer for every Persona.
import Foundation
import Plugins

@MainActor
public final class WebStoreInstaller {
    private let client: WebStoreClient

    nonisolated public init(client: WebStoreClient) {
        self.client = client
    }

    /// The plugin among `plugins` that holds the extension `id`, from the Web Store or not, a version of a pair among them, or nil, also for text that is not an identifier. A store page's row in the site settings popover names it as installed.
    nonisolated public static func installedPlugin(of id: String, among plugins: [InstalledPlugin]) -> InstalledPlugin? {
        guard let id = WebStore.identifier(id) else { return nil }
        let pluginID = WebExtensionManifest.pluginID(of: id)
        return plugins.first { $0.kind == .webExtension && $0.manifest.id == pluginID }
    }

    /// Downloads the current package of the extension `id`, an identifier as `WebStore.extensionID(from:)` reads it, and stages it in the Persona of `plugins` with the origin `webStore(id)`, for the review. Throws `WebStoreError` when the store offers no package, when the Persona has the store's current version installed from the store, which downloads nothing, and when the download fails its checks; `PluginError` when staging refuses the package, and `PluginError.closed`, without asking or downloading, once the session has closed `plugins` as it deleted the Persona; and the system's error when the network fails. Cancelling the task throws `CancellationError` at whatever step it comes: it stops the request or the download, and a package that staging finished meanwhile is discarded. The downloaded file is deleted once the package is staged or refused, and on every failure.
    public func stage(_ id: String, in plugins: PluginManager) async throws -> PluginPackage {
        do {
            let package = try await downloadAndStage(id, in: plugins)
            // Staging does not stop for a cancellation, so what it staged meanwhile goes.
            guard !Task.isCancelled else {
                plugins.discard(package)
                throw CancellationError()
            }
            return package
        } catch {
            // A step that a cancellation ends in another way, as a cancelled request does with the system's error, ends with the cancellation.
            try Task.checkCancellation()
            throw error
        }
    }

    /// The steps of `stage(_:in:)`, which ask and download nothing for a closed manager or a cancelled task.
    private func downloadAndStage(_ id: String, in plugins: PluginManager) async throws -> PluginPackage {
        guard let id = WebStore.identifier(id) else { throw WebStoreError.unknownExtension(id) }
        guard !plugins.isClosed else { throw PluginError.closed }
        let release = try await currentRelease(of: id)
        if let installed = plugins.plugins.first(where: { $0.origin == .webStore(id) && $0.manifest.version == release.version }) {
            throw WebStoreError.alreadyInstalled(name: installed.manifest.name, version: release.version)
        }
        // The task may have been cancelled, or the Persona deleted, while the store answered.
        try Task.checkCancellation()
        guard !plugins.isClosed else { throw PluginError.closed }
        // `Staging/` is cleared at launch, so a download that a quit cuts short leaves nothing behind.
        try FileManager.default.createDirectory(at: plugins.stagingDirectory, withIntermediateDirectories: true)
        let file = plugins.stagingDirectory.appendingPathComponent("\(UUID().uuidString).crx")
        defer { try? FileManager.default.removeItem(at: file) }
        try await client.download(release, to: file)
        try Task.checkCancellation()
        return try await plugins.stage(file, origin: .webStore(id))
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
}
