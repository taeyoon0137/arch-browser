// The CloudKit database that sync uses (`docs/sync.md`, Container, database, and zone; sync decisions 6 and 13): the container that the app's own entitlements name and its environment. Development and Production hold separate databases, and so do two containers, so the engine's state and the mirror in `sync.json` belong to one container and environment.
import CryptoKit
import Foundation

/// The CloudKit database that sync uses, as the app's own entitlements name it (`SyncAvailability`).
public struct SyncDatabase: Hashable, Sendable {
    /// The container, the first that the app's entitlement lists. The identifier belongs to the user's team, so it goes only to `CKContainer(identifier:)` and is never logged, shown, or written to a file (Working Rule 8 of `docs/plan.md`).
    public var containerIdentifier: String
    /// The CloudKit environment, `Development` or `Production`, as the app's `com.apple.developer.icloud-container-environment` entitlement gives it. Nil without that entitlement, where CloudKit picks the environment by the build's signing.
    public var environment: String?

    public init(containerIdentifier: String, environment: String?) {
        self.containerIdentifier = containerIdentifier
        self.environment = environment
    }

    /// Tells databases apart without naming the container: the SHA-256 of the identifier and the environment, in lowercase hexadecimal. `sync.json` keeps it, so a build for another container or environment starts with a first sync instead of using another database's change token and mirror (`SyncMirror.read(from:database:)`).
    public var digest: String {
        SHA256.hash(data: Data("\(containerIdentifier)\n\(environment ?? "")".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
