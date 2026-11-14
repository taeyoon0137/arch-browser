// Whether this Mac can sync (`docs/sync.md`, Requirements, Accounts and removed data, and User interface; sync decisions 6 and 13): first the app's own iCloud entitlements, then the account status of the container they name. `CKContainer` raises an exception for a container the app is not entitled to, so without the entitlements, as in an ad hoc signed build or the test runner, the check creates no CloudKit object.
import CloudKit
import Foundation
import Security

/// Checks whether sync can run on this Mac. The controller checks before it creates the sync engine, again when the app becomes active and when the container reports an account change, and Settings ▸ Sync shows the reason while sync cannot run.
public struct SyncAvailability: Sendable {
    /// What a check found.
    public enum Status: Hashable, Sendable {
        /// Sync can run with this database: the first container that the app's entitlement lists, in the environment its entitlement names.
        case available(SyncDatabase)
        case unavailable(Reason)
    }

    /// Why sync cannot run.
    public enum Reason: Hashable, Sendable {
        /// The app's entitlements lack the CloudKit service or a container, or CloudKit refused the container as one the app is not entitled to.
        case notSignedForICloud
        case noAccount
        case restricted
        /// The account is temporarily unavailable, its status is unknown or one this build does not know, or the check failed.
        case temporarilyUnavailable

        /// The sentence Settings ▸ Sync shows below the disabled toggle (`docs/sync.md`, User interface).
        public var message: String {
            switch self {
            case .notSignedForICloud: "This copy of Arch isn\u{2019}t signed for iCloud, so it can\u{2019}t sync."
            case .noAccount: "Sign in to iCloud in System Settings to sync."
            case .restricted: "iCloud is restricted on this Mac."
            case .temporarilyUnavailable: "iCloud isn\u{2019}t available right now. Arch checks again when it becomes active."
            }
        }
    }

    /// Reads an entitlement of the app's own process: a list of strings or a string. Nil when the app lacks it or its value is neither.
    typealias EntitlementReader = @Sendable (_ key: String) -> (any Sendable)?
    /// Asks the container with this identifier for the status of the Mac's iCloud account.
    typealias AccountStatusProvider = @Sendable (_ containerIdentifier: String) async throws -> CKAccountStatus

    static let servicesKey = "com.apple.developer.icloud-services"
    static let containersKey = "com.apple.developer.icloud-container-identifiers"
    static let environmentKey = "com.apple.developer.icloud-container-environment"

    private let readEntitlement: EntitlementReader
    private let accountStatus: AccountStatusProvider

    /// Reads this process's entitlements and asks CloudKit for the account status.
    public init() {
        self.init(readEntitlement: Self.ownEntitlement, accountStatus: Self.containerAccountStatus)
    }

    /// Reads entitlements and account status through the given calls, which tests replace.
    init(readEntitlement: @escaping EntitlementReader, accountStatus: @escaping AccountStatusProvider) {
        self.readEntitlement = readEntitlement
        self.accountStatus = accountStatus
    }

    /// Whether sync can run now. It asks for the account status only when the entitlements name a container.
    public func check() async -> Status {
        guard let database = entitledDatabase() else { return .unavailable(.notSignedForICloud) }
        do {
            return Self.status(of: try await accountStatus(database.containerIdentifier), database: database)
        } catch {
            return .unavailable(Self.reason(for: error))
        }
    }

    /// The database sync opens: the first entry of the container identifiers entitlement, when the iCloud services entitlement lists CloudKit (sync decision 13), with the container environment entitlement's value, nil when it is missing or not a string (sync decision 6). Nil without a container, including for an empty first entry.
    func entitledDatabase() -> SyncDatabase? {
        guard (readEntitlement(Self.servicesKey) as? [String])?.contains("CloudKit") == true,
              let first = (readEntitlement(Self.containersKey) as? [String])?.first, !first.isEmpty else { return nil }
        return SyncDatabase(containerIdentifier: first, environment: readEntitlement(Self.environmentKey) as? String)
    }

    /// The status for an account status that CloudKit reported for the database's container.
    static func status(of accountStatus: CKAccountStatus, database: SyncDatabase) -> Status {
        switch accountStatus {
        case .available: .available(database)
        case .noAccount: .unavailable(.noAccount)
        case .restricted: .unavailable(.restricted)
        case .temporarilyUnavailable, .couldNotDetermine: .unavailable(.temporarilyUnavailable)
        @unknown default: .unavailable(.temporarilyUnavailable)
        }
    }

    /// The reason for a failed account check. CloudKit's refusal of the container itself needs another build, so it counts as not signed for iCloud; any other failure may pass, so the next check tries again.
    static func reason(for error: Error) -> Reason {
        switch (error as? CKError)?.code {
        case .missingEntitlement?, .badContainer?: .notSignedForICloud
        default: .temporarilyUnavailable
        }
    }

    /// Reads the entitlement from this process's code signature.
    static let ownEntitlement: EntitlementReader = { key in
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        if let list = value as? [String] { return list }
        return value as? String
    }

    private static let containerAccountStatus: AccountStatusProvider = { containerIdentifier in
        try await CKContainer(identifier: containerIdentifier).accountStatus()
    }
}
