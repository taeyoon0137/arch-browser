// Installs extensions from the Web Store (`docs/web-store.md`, Install flow): asks the store for an extension's current package, downloads it into the Persona's staging folder unless the Persona has that version installed from the store, and stages it with the origin `webStore`, which checks the store's signature and the identifier, for the same review as any package. The session owns one installer for every Persona.
import Foundation
import Plugins

@MainActor
public final class WebStoreInstaller {
    private let client: WebStoreClient

    nonisolated public init(client: WebStoreClient) {
        self.client = client
    }

    /// Downloads the current package of the extension `id`, an identifier as `WebStore.extensionID(from:)` reads it, and stages it in the Persona of `plugins` with the origin `webStore(id)`, for the review. Throws `WebStoreError` when the store offers no package, when the Persona has the store's current version installed from the store, which downloads nothing, and when the download fails its checks; `PluginError` when staging refuses the package; and the system's error when the network fails. Cancelling the task stops the request or the download. The downloaded file is deleted once the package is staged or refused, and on every failure.
    public func stage(_ id: String, in plugins: PluginManager) async throws -> PluginPackage {
        guard let id = WebStore.identifier(id) else { throw WebStoreError.unknownExtension(id) }
        let release = try await currentRelease(of: id)
        if let installed = plugins.plugins.first(where: { $0.origin == .webStore(id) && $0.manifest.version == release.version }) {
            throw WebStoreError.alreadyInstalled(name: installed.manifest.name, version: release.version)
        }
        // `Staging/` is cleared at launch, so a download that a quit cuts short leaves nothing behind.
        try FileManager.default.createDirectory(at: plugins.stagingDirectory, withIntermediateDirectories: true)
        let file = plugins.stagingDirectory.appendingPathComponent("\(UUID().uuidString).crx")
        defer { try? FileManager.default.removeItem(at: file) }
        try await client.download(release, to: file)
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
