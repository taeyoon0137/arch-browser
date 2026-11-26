@testable import Browsing
import CloudKit
import Foundation
import Testing
@testable import Sync

@MainActor @Suite struct FavoriteRowsSyncTests {
    typealias Mac = TwoMacRecoveryTests.Mac
    typealias Zone = TwoMacRecoveryTests.Zone

    /// Two independent sessions, stores, mirrors, and controllers share only fake CloudKit records.
    @Test func personaLayoutsReachTheOtherMacAndRowOnlyEditsSurviveRelaunch() async throws {
        let zone = Zone()
        let a = try Mac(zone: zone), b = try Mac(zone: zone)
        defer { a.clean(); b.clean() }
        let work = a.session.addPersona(named: "Work")
        for personaID in [Persona.defaultID, work.id] {
            let favorites = (0..<4).map {
                Favorite(url: URL(string: "about:blank#\(personaID)-\($0)")!, title: "Favorite \($0)", personaID: personaID)
            }
            a.session.addFavorites(favorites, in: personaID)
        }
        a.session.setFavoriteRows([1, 2, 1], in: Persona.defaultID)
        a.session.setFavoriteRows([3, 1], in: work.id)
        await a.controller.setEnabled(true)
        try await a.flush()
        await b.controller.setEnabled(true)
        try await b.flush()
        #expect(b.session.favoriteRows(in: Persona.defaultID) == [1, 2, 1])
        #expect(b.session.favoriteRows(in: work.id) == [3, 1])
        #expect(zone.records["default"]?.encryptedValues["favoriteRows"] as? String == "[1,2,1]")
        #expect(zone.records[work.id.uuidString]?.encryptedValues["favoriteRows"] as? String == "[3,1]")

        let favorites = b.session.favorites
        b.session.setFavoriteRows([2, 2], in: Persona.defaultID)
        try await b.flush()
        #expect(b.session.favorites == favorites)
        await a.controller.refresh()
        try await a.flush()
        #expect(a.session.favoriteRows(in: Persona.defaultID) == [2, 2])
        #expect(a.session.favoriteRows(in: work.id) == [3, 1])
        #expect(a.controller.lastError == nil && b.controller.lastError == nil)

        try b.launch()
        #expect(b.session.favoriteRows(in: Persona.defaultID) == [2, 2])
        #expect(b.session.favoriteRows(in: work.id) == [3, 1])
        await b.controller.refreshIfRequested()
        try await b.flush()
        #expect(b.session.favoriteRows(in: Persona.defaultID) == [2, 2])
        #expect(b.session.favoriteRows(in: work.id) == [3, 1])
        #expect(b.controller.lastError == nil)
    }

    @Test func firstSyncNormalizesAfterMatchingFavoriteIDs() async throws {
        let zone = Zone()
        let a = try Mac(zone: zone), b = try Mac(zone: zone)
        defer { a.clean(); b.clean() }
        for (mac, count) in [(a, 4), (b, 5)] {
            let favorites = (0..<count).map {
                Favorite(url: URL(string: "about:blank#favorite-\($0)")!, title: "Favorite \($0)", personaID: Persona.defaultID)
            }
            mac.session.addFavorites(favorites, in: Persona.defaultID)
        }
        a.session.setFavoriteRows([1, 2, 1], in: Persona.defaultID)
        b.session.setFavoriteRows([2, 2, 1], in: Persona.defaultID)
        await a.controller.setEnabled(true)
        try await a.flush()
        await b.controller.setEnabled(true)
        try await b.flush()
        #expect(b.session.favorites(in: Persona.defaultID).count == 5)
        #expect(b.session.favoriteRows(in: Persona.defaultID) == [1, 2, 2])
        await a.controller.refresh()
        try await a.flush()
        #expect(a.session.favorites(in: Persona.defaultID).count == 5)
        #expect(a.session.favoriteRows(in: Persona.defaultID) == [1, 2, 2])
        #expect(a.controller.lastError == nil && b.controller.lastError == nil)
    }
}
