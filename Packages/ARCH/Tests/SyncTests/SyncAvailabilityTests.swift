// Whether this Mac can sync (docs/sync.md, Requirements and User interface; sync decisions 6 and 13): the entitlements read before any CloudKit call, the container that the account check asks and the environment that comes with it, the reason for each account status and failure, and the wording Settings shows.
import CloudKit
import Foundation
import Testing
@testable import Sync

@Suite struct SyncAvailabilityTests {
    /// Placeholders; no real container identifier appears in the repository.
    private let first = "iCloud.example.first"
    private let second = "iCloud.example.second"

    /// The containers that the account check was asked about, in order.
    private actor Calls {
        private(set) var containers: [String] = []

        func record(_ container: String) {
            containers.append(container)
        }
    }

    /// An availability with these entitlement values, nil for a missing entitlement, whose account check records its container and gives `result`.
    private func availability(services: [String]?, containers: [String]?, environment: (any Sendable)? = "Production", calls: Calls, result: @escaping @Sendable () throws -> CKAccountStatus = { .available }) -> SyncAvailability {
        var values: [String: any Sendable] = [:]
        values[SyncAvailability.servicesKey] = services
        values[SyncAvailability.containersKey] = containers
        values[SyncAvailability.environmentKey] = environment
        let entitlements = values
        return SyncAvailability(readEntitlement: { entitlements[$0] }, accountStatus: { container in
            await calls.record(container)
            return try result()
        })
    }

    @Test func missingEntitlementGivesTheUnsignedReasonWithoutAskingForTheAccount() async {
        let cases: [([String]?, [String]?)] = [
            (nil, nil),
            (nil, [first]),
            (["CloudKit"], nil),
            (["CloudKit"], []),
            (["CloudKit"], [""]),
            // iCloud Drive alone gives no CloudKit database.
            (["CloudDocuments"], [first]),
        ]
        for (services, containers) in cases {
            let calls = Calls()
            #expect(await availability(services: services, containers: containers, calls: calls).check() == .unavailable(.notSignedForICloud))
            #expect(await calls.containers.isEmpty)
        }
    }

    @Test func asksForTheEntitlementsFirstContainer() async {
        let calls = Calls()
        let status = await availability(services: ["CloudDocuments", "CloudKit"], containers: [first, second], calls: calls).check()
        #expect(status == .available(SyncDatabase(containerIdentifier: first, environment: "Production")))
        #expect(await calls.containers == [first])
    }

    /// The environment tells the database apart for `sync.json` (sync decision 6); without the entitlement, or with a value that is not a string, CloudKit picks it.
    @Test func givesTheEntitlementsEnvironmentWithTheContainer() async {
        let cases: [((any Sendable)?, String?)] = [
            ("Development", "Development"),
            ("Production", "Production"),
            (nil, nil),
            (["Production"], nil),
        ]
        for (entitlement, environment) in cases {
            let calls = Calls()
            #expect(await availability(services: ["CloudKit"], containers: [first], environment: entitlement, calls: calls).check() == .available(SyncDatabase(containerIdentifier: first, environment: environment)))
        }
    }

    @Test func mapsEachAccountStatusToItsReason() async throws {
        let unknown = try #require(CKAccountStatus(rawValue: 99))
        let cases: [(CKAccountStatus, SyncAvailability.Status)] = [
            (.available, .available(SyncDatabase(containerIdentifier: first, environment: "Production"))),
            (.noAccount, .unavailable(.noAccount)),
            (.restricted, .unavailable(.restricted)),
            (.temporarilyUnavailable, .unavailable(.temporarilyUnavailable)),
            (.couldNotDetermine, .unavailable(.temporarilyUnavailable)),
            // A status from a later macOS.
            (unknown, .unavailable(.temporarilyUnavailable)),
        ]
        for (accountStatus, expected) in cases {
            let calls = Calls()
            #expect(await availability(services: ["CloudKit"], containers: [first], calls: calls, result: { accountStatus }).check() == expected)
            #expect(await calls.containers == [first])
        }
    }

    @Test func mapsAFailedAccountCheckToAReason() async {
        let cases: [(any Error, SyncAvailability.Reason)] = [
            (CKError(.missingEntitlement), .notSignedForICloud),
            (CKError(.badContainer), .notSignedForICloud),
            (CKError(.networkUnavailable), .temporarilyUnavailable),
            (CKError(.notAuthenticated), .temporarilyUnavailable),
            (CocoaError(.fileReadUnknown), .temporarilyUnavailable),
        ]
        for (error, reason) in cases {
            let calls = Calls()
            #expect(await availability(services: ["CloudKit"], containers: [first], calls: calls, result: { throw error }).check() == .unavailable(reason))
        }
    }

    @Test func reasonsUseTheSettingsWording() {
        #expect(SyncAvailability.Reason.notSignedForICloud.message == "This copy of Arch isn\u{2019}t signed for iCloud, so it can\u{2019}t sync.")
        #expect(SyncAvailability.Reason.noAccount.message == "Sign in to iCloud in System Settings to sync.")
        #expect(SyncAvailability.Reason.restricted.message == "iCloud is restricted on this Mac.")
        #expect(SyncAvailability.Reason.temporarilyUnavailable.message == "iCloud isn\u{2019}t available right now. Arch checks again when it becomes active.")
    }

    /// The test runner has no iCloud entitlements, so the app's own reader finds none and the check never reaches CloudKit, where `CKContainer` would raise an exception. The public initializer, which the controller uses, returns before it creates a container too.
    @Test func theTestRunnerIsNotSignedForICloud() async throws {
        // Stop before the public initializer's check if the runner ever had the entitlements, since its container would be real.
        try #require(SyncAvailability.ownEntitlement(SyncAvailability.servicesKey) == nil)
        try #require(SyncAvailability.ownEntitlement(SyncAvailability.containersKey) == nil)
        #expect(SyncAvailability.ownEntitlement(SyncAvailability.environmentKey) == nil)
        #expect(await SyncAvailability().check() == .unavailable(.notSignedForICloud))
        let calls = Calls()
        let availability = SyncAvailability(readEntitlement: SyncAvailability.ownEntitlement, accountStatus: { container in
            await calls.record(container)
            return .available
        })
        #expect(await availability.check() == .unavailable(.notSignedForICloud))
        #expect(await calls.containers.isEmpty)
    }
}
