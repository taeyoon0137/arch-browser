// The Settings list that sync copies (docs/sync.md, Settings list; sync decision 12): each listed key against the app's constant, reading and applying values, refusing what the list does not allow, finding changes made here, and what the settings comparison covers.
import ARCHEngine
import Browsing
import Foundation
import Preferences
import Testing
@testable import Sync

@MainActor
@Suite struct SyncedSettingsTests {
    private let defaults = TemporaryDefaults()
    private var store: UserDefaults { defaults.store }

    private let appearance = AppearanceSetting.defaultsKey
    private let tintStrength = TintStrength.defaultsKey
    private let searchEngine = SearchEngine.defaultsKey
    private let archiveAfterHours = BrowserSession.archiveAfterHoursKey

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// A fetched or mirrored `Setting` record; a nil value gives a record without `value`.
    private func record(_ key: String, _ value: SyncValue?, at seconds: TimeInterval = 10) -> SyncRecord {
        SyncRecord(recordType: .setting, recordName: key, fields: value.map { ["value": $0] } ?? [:], fieldModifiedAt: ["value": date(seconds)], modifiedAt: date(seconds))
    }

    private func record(_ key: String, _ text: String, at seconds: TimeInterval = 10) -> SyncRecord {
        record(key, .text(text), at: seconds)
    }

    @Test func listsEachKeyAsItsConstantWithTheAppsValues() {
        #expect(SyncedSettings.list.map(\.key) == [
            AppearanceSetting.defaultsKey,
            TintStrength.defaultsKey,
            EngineRegistry.defaultEngineKey,
            SearchEngine.defaultsKey,
            BrowserSession.archiveAfterHoursKey,
            TabUnloading.unloadAfterHoursKey,
            BrowserSession.opensLinksInSmallWindowKey,
            BrowserSession.asksWhereToSaveDownloadsKey,
        ])
        func values(_ key: String) -> SyncedSetting.Values? { SyncedSettings.setting(forKey: key)?.values }
        #expect(values(AppearanceSetting.defaultsKey) == .oneOf(AppearanceSetting.allCases.map(\.rawValue)))
        #expect(values(TintStrength.defaultsKey) == .oneOf(TintStrength.allCases.map(\.rawValue)))
        #expect(values(EngineRegistry.defaultEngineKey) == .oneOf(EngineKind.allCases.map(\.rawValue)))
        #expect(values(SearchEngine.defaultsKey) == .oneOf(SearchEngine.allCases.map(\.rawValue)))
        // Settings ▸ Sidebar's stepper takes 0 to 168 hours.
        #expect(values(BrowserSession.archiveAfterHoursKey) == .wholeNumber(0...168))
        #expect(values(TabUnloading.unloadAfterHoursKey) == .wholeNumber(0...168))
        #expect(values(BrowserSession.opensLinksInSmallWindowKey) == .flag)
        #expect(values(BrowserSession.asksWhereToSaveDownloadsKey) == .flag)
        // Paths, shortcuts, zoom, and keys that only a later build lists stay on each Mac.
        for key in ["ARCHDownloadsFolder", "ARCHShortcuts", "ARCHZoomFactorsByHost", "ARCHSyncEnabled", "ARCHFutureSetting"] {
            #expect(SyncedSettings.setting(forKey: key) == nil)
        }
    }

    @Test func appliesAndReadsEveryListedValue() {
        let settings = SyncedSettings(defaults: store)
        for setting in SyncedSettings.list {
            let texts: [String] = switch setting.values {
            case .oneOf(let allowed): allowed
            case .wholeNumber(let range): [String(range.lowerBound), "24", String(range.upperBound)]
            case .flag: ["true", "false"]
            }
            for text in texts {
                #expect(settings.apply(record(setting.key, text)))
                #expect(settings.text(forKey: setting.key) == text)
            }
        }
    }

    @Test func savesEachValueAsTheAppReadsIt() {
        let settings = SyncedSettings(defaults: store)
        for (key, text) in [(appearance, "dark"), (tintStrength, "strong"), (EngineRegistry.defaultEngineKey, "webKit"), (searchEngine, "duckDuckGo"), (archiveAfterHours, "24"), (TabUnloading.unloadAfterHoursKey, "4"), (BrowserSession.opensLinksInSmallWindowKey, "false"), (BrowserSession.asksWhereToSaveDownloadsKey, "true")] {
            #expect(settings.apply(record(key, text)))
        }
        #expect(store.string(forKey: appearance).flatMap(AppearanceSetting.init(rawValue:)) == .dark)
        #expect(store.string(forKey: tintStrength).flatMap(TintStrength.init(rawValue:)) == .strong)
        #expect(store.string(forKey: EngineRegistry.defaultEngineKey).flatMap(EngineKind.init(rawValue:)) == .webKit)
        #expect(store.string(forKey: searchEngine).flatMap(SearchEngine.init(rawValue:)) == .duckDuckGo)
        // Integers and Booleans, as `@AppStorage` writes them.
        #expect(store.object(forKey: archiveAfterHours) as? Int == 24)
        #expect(store.object(forKey: TabUnloading.unloadAfterHoursKey) as? Int == 4)
        #expect(store.object(forKey: BrowserSession.opensLinksInSmallWindowKey) as? Bool == false)
        #expect(store.object(forKey: BrowserSession.asksWhereToSaveDownloadsKey) as? Bool == true)

        // Values the app saved read as the record's text.
        store.set(12, forKey: archiveAfterHours)
        store.set(true, forKey: BrowserSession.opensLinksInSmallWindowKey)
        store.set("light", forKey: appearance)
        #expect(settings.text(forKey: archiveAfterHours) == "12")
        #expect(settings.text(forKey: BrowserSession.opensLinksInSmallWindowKey) == "true")
        #expect(settings.text(forKey: appearance) == "light")
    }

    @Test func refusesADisallowedValueAndEveryUnlistedKey() {
        store.set("dark", forKey: appearance)
        store.set(12, forKey: archiveAfterHours)
        store.set(true, forKey: BrowserSession.asksWhereToSaveDownloadsKey)
        let settings = SyncedSettings(defaults: store)
        var applied: [String] = []
        settings.onApplied = { applied.append($0) }

        #expect(!settings.apply(record(appearance, "purple")))
        for text in ["169", "-1", "+12", "012", "12.5", ""] {
            #expect(!settings.apply(record(archiveAfterHours, text)))
        }
        for text in ["yes", "1", "TRUE"] {
            #expect(!settings.apply(record(BrowserSession.asksWhereToSaveDownloadsKey, text)))
        }
        // A value of another kind, or none, as a later build might write.
        #expect(!settings.apply(record(appearance, .number(1))))
        #expect(!settings.apply(record(appearance, .reference("light"))))
        #expect(!settings.apply(record(appearance, nil)))
        #expect(store.string(forKey: appearance) == "dark")
        #expect(store.object(forKey: archiveAfterHours) as? Int == 12)
        #expect(store.object(forKey: BrowserSession.asksWhereToSaveDownloadsKey) as? Bool == true)

        for key in ["ARCHFutureSetting", "ARCHDownloadsFolder", "ARCHShortcuts"] {
            #expect(!settings.apply(record(key, "12")))
            #expect(store.object(forKey: key) == nil)
            #expect(settings.text(forKey: key) == nil)
        }
        // Only a `Setting` record applies.
        #expect(!settings.apply(SyncRecord(recordType: .space, recordName: appearance, fields: ["value": .text("light")], modifiedAt: date(10))))
        #expect(store.string(forKey: appearance) == "dark")
        #expect(applied.isEmpty)

        // A saved value that the list does not allow reads as none, so it is never sent.
        store.set("purple", forKey: appearance)
        store.set("12", forKey: archiveAfterHours)
        store.set(200, forKey: tintStrength)
        #expect(settings.text(forKey: appearance) == nil)
        #expect(settings.text(forKey: archiveAfterHours) == nil)
        #expect(settings.text(forKey: tintStrength) == nil)
    }

    @Test func onAppliedRunsOnceForEachValueSaved() {
        store.set("system", forKey: appearance)
        let settings = SyncedSettings(defaults: store)
        var applied: [String] = []
        settings.onApplied = { applied.append($0) }

        #expect(settings.apply(record(appearance, "dark")))
        #expect(applied == [appearance])
        // The value the key already has needs no save.
        #expect(settings.apply(record(appearance, "dark", at: 20)))
        #expect(applied == [appearance])
    }

    @Test func reportsOnlyKeysChangedHere() {
        store.set("dark", forKey: appearance)
        let settings = SyncedSettings(defaults: store)
        #expect(settings.changedKeys().isEmpty)

        store.set("bing", forKey: searchEngine)
        store.set("medium", forKey: tintStrength)
        #expect(settings.changedKeys() == [tintStrength, searchEngine])
        #expect(settings.changedKeys().isEmpty)

        // Unlisted keys and a value saved again are no change.
        store.set("/Users/Shared", forKey: "ARCHDownloadsFolder")
        store.set(12, forKey: "ARCHFutureSetting")
        store.set("dark", forKey: appearance)
        #expect(settings.changedKeys().isEmpty)

        // An applied value is no change made here, even to a check that the save's own notification starts.
        let seen = Seen()
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: store, queue: nil) { _ in
            MainActor.assumeIsolated { seen.keys.append(settings.changedKeys()) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(settings.apply(record(appearance, "light")))
        #expect(seen.keys == [[]])
        #expect(settings.changedKeys().isEmpty)

        store.removeObject(forKey: searchEngine)
        #expect(seen.keys == [[], [searchEngine]])
    }

    @Test func comparisonListsEverySavedValueInListOrder() {
        store.set(false, forKey: BrowserSession.opensLinksInSmallWindowKey)
        store.set("strong", forKey: tintStrength)
        store.set(0, forKey: archiveAfterHours)
        let comparison = SyncedSettings(defaults: store).comparison(mirror: [], pending: [])
        #expect(comparison.records == [
            SyncRecord(recordType: .setting, recordName: tintStrength, fields: ["value": .text("strong")], modifiedAt: .distantPast),
            SyncRecord(recordType: .setting, recordName: archiveAfterHours, fields: ["value": .text("0")], modifiedAt: .distantPast),
            SyncRecord(recordType: .setting, recordName: BrowserSession.opensLinksInSmallWindowKey, fields: ["value": .text("false")], modifiedAt: .distantPast),
        ])
        #expect(comparison.contains(record(tintStrength, "subtle")))
        // A sidebar record with a listed key's name is outside the scope.
        #expect(!comparison.contains(SyncRecord(recordType: .space, recordName: tintStrength, modifiedAt: date(10))))
    }

    @Test func comparisonLeavesOutUnlistedKeysAndRefusedMirrorValuesUntilChangedHere() {
        store.set("dark", forKey: appearance)
        store.set("subtle", forKey: tintStrength)
        store.set("bing", forKey: searchEngine)
        store.set(12, forKey: archiveAfterHours)
        // A newer build wrote a search engine and a kind of tint value that this build refuses, and a key that only it lists.
        let mirror = [record(appearance, "dark"), record(tintStrength, .number(2)), record(searchEngine, "newer-engine"), record("ARCHFutureSetting", "12")]
        let settings = SyncedSettings(defaults: store)
        #expect(!settings.apply(mirror[2]))

        let held = settings.comparison(mirror: mirror, pending: [])
        #expect(held.records.map(\.recordName) == [appearance, archiveAfterHours])
        #expect(held.heldOut == [tintStrength, searchEngine])
        #expect(held.contains(mirror[0]))
        #expect(!held.contains(mirror[1]))
        #expect(!held.contains(mirror[2]))
        #expect(!held.contains(mirror[3]))
        let heldChanges = SyncDiff.changes(local: held.records, scope: held.contains, mirror: mirror, pending: [], foundAt: date(100))
        #expect(heldChanges.saves.map(\.recordName) == [archiveAfterHours])
        #expect(heldChanges.deletions.isEmpty)
        // A relaunch with nothing pending holds them too.
        #expect(SyncedSettings(defaults: store).comparison(mirror: mirror, pending: []).records.map(\.recordName) == [appearance, archiveAfterHours])

        // A change here, found by a check or not yet, brings the key back, and its save replaces the newer build's value.
        store.set("google", forKey: searchEngine)
        #expect(settings.comparison(mirror: mirror, pending: []).records.map(\.recordName) == [appearance, searchEngine, archiveAfterHours])
        #expect(settings.changedKeys() == [searchEngine])
        let changed = settings.comparison(mirror: mirror, pending: [])
        #expect(changed.contains(mirror[2]))
        #expect(changed.heldOut == [tintStrength])
        let changes = SyncDiff.changes(local: changed.records, scope: changed.contains, mirror: mirror, pending: [], foundAt: date(200))
        let searchSave = changes.saves.first { $0.recordName == searchEngine }
        #expect(searchSave?[.value] == .text("google"))
        #expect(searchSave?.fieldModifiedAt["value"] == date(200))
        #expect(changes.deletions.isEmpty)

        // After a relaunch, the pending save keeps it in until it is sent.
        let relaunched = SyncedSettings(defaults: store)
        #expect(relaunched.comparison(mirror: mirror, pending: changes.saves).records.map(\.recordName) == [appearance, searchEngine, archiveAfterHours])
        #expect(relaunched.comparison(mirror: mirror, pending: []).records.map(\.recordName) == [appearance, archiveAfterHours])

        // Another refused value, which the merge chose over the unsent google as the later edit, holds it out again, also after a relaunch, so the earlier pending save is dropped rather than sent over that value.
        let newer = record(searchEngine, "another-engine", at: 300)
        #expect(!settings.apply(newer))
        let newerMirror = [mirror[0], mirror[1], newer, mirror[3]]
        for heldAgain in [settings.comparison(mirror: newerMirror, pending: changes.saves), SyncedSettings(defaults: store).comparison(mirror: newerMirror, pending: changes.saves)] {
            #expect(heldAgain.records.map(\.recordName) == [appearance, archiveAfterHours])
            #expect(heldAgain.heldOut == [tintStrength, searchEngine])
            let againChanges = SyncDiff.changes(local: heldAgain.records, scope: heldAgain.contains, mirror: newerMirror, pending: changes.saves, foundAt: date(400))
            #expect(!againChanges.saves.contains { $0.recordName == searchEngine })
        }

        // A pending save later than the refused value, which the merge chose over it, keeps the key in with its own edit time.
        let later = changes.saves.map { $0.recordName == searchEngine ? record(searchEngine, "google", at: 350) : $0 }
        let kept = SyncedSettings(defaults: store).comparison(mirror: newerMirror, pending: later)
        #expect(kept.records.map(\.recordName) == [appearance, searchEngine, archiveAfterHours])
        #expect(kept.heldOut == [tintStrength])
        let keptSave = SyncDiff.changes(local: kept.records, scope: kept.contains, mirror: newerMirror, pending: later, foundAt: date(400)).saves.first { $0.recordName == searchEngine }
        #expect(keptSave?[.value] == .text("google"))
        #expect(keptSave?.fieldModifiedAt["value"] == date(350))
    }

    @Test func comparisonDeletesNoSettingRecord() {
        store.set("dark", forKey: appearance)
        let mirror = [record(appearance, "dark"), record(tintStrength, "medium"), record(searchEngine, "bing")]
        let settings = SyncedSettings(defaults: store)
        // Keys without a saved value here are outside the scope.
        let comparison = settings.comparison(mirror: mirror, pending: [])
        #expect(comparison.records.map(\.recordName) == [appearance])
        #expect(!comparison.contains(mirror[1]))
        #expect(SyncDiff.changes(local: comparison.records, scope: comparison.contains, mirror: mirror, pending: [], foundAt: date(100)) == SyncChanges())
    }
}

/// The keys each check found, collected on the main actor by a notification observer.
@MainActor
private final class Seen {
    var keys: [[String]] = []
}

/// Defaults of their own for one test, named after the checkout and the test and emptied when it starts and when it ends. macOS keeps an empty file for a removed domain, so each test reuses its name on every run in a checkout.
private final class TemporaryDefaults {
    private let name = "test.arch.synced-settings.\(checkoutID).\(Test.current.map { String($0.name.prefix { $0 != "(" }) } ?? UUID().uuidString)"
    let store: UserDefaults

    init() {
        store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
    }

    deinit {
        store.removePersistentDomain(forName: name)
    }
}

/// A part of the defaults names that stays the same on every run in a checkout and differs between checkouts, so that runs in two checkouts at the same time keep apart: a hash of this file's path.
private let checkoutID = String(#filePath.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 36)
