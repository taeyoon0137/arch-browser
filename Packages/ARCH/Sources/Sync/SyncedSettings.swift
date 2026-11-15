// The settings that sync copies between Macs (`docs/sync.md`, Settings list; sync decision 12): the listed `UserDefaults` keys, the values each allows, and their text as a `Setting` record's `value`. Every other key stays on each Mac. The keys and values are written out here in one list, and `SyncTests` compare each with its module's constant.
import Foundation

/// One key of the Settings list and the values it allows.
public struct SyncedSetting: Hashable, Sendable {
    /// The values a key allows, and how `UserDefaults` stores them, the way the app's settings write them.
    public enum Values: Hashable, Sendable {
        /// One of these raw values, stored as a string.
        case oneOf([String])
        /// A whole number in the range, written as decimal digits and stored as an integer.
        case wholeNumber(ClosedRange<Int>)
        /// `true` or `false`, stored as a Boolean.
        case flag
    }

    /// The `UserDefaults` key, which is also the record name.
    public let key: String
    public let values: Values

    public init(key: String, values: Values) {
        self.key = key
        self.values = values
    }

    /// Whether `text` is an allowed value in the record's form. A whole number has no sign and no leading zeros.
    public func allows(_ text: String) -> Bool {
        switch values {
        case .oneOf(let allowed): return allowed.contains(text)
        case .wholeNumber(let range): return Int(text).map { range.contains($0) && String($0) == text } ?? false
        case .flag: return text == "true" || text == "false"
        }
    }

    /// The value saved in `defaults` as the record's text. Nil when nothing is saved or the saved value is not allowed, including a value of another type, which only a hand edit writes.
    public func text(in defaults: UserDefaults) -> String? {
        let object = defaults.object(forKey: key)
        let text: String?
        switch values {
        case .oneOf: text = object as? String
        case .wholeNumber: text = (object as? Int).map(String.init)
        case .flag: text = (object as? Bool).map { $0 ? "true" : "false" }
        }
        return text.flatMap { allows($0) ? $0 : nil }
    }

    /// Saves the allowed value `text` in `defaults` with the type the app's settings write.
    func write(_ text: String, to defaults: UserDefaults) {
        switch values {
        case .oneOf: defaults.set(text, forKey: key)
        case .wholeNumber: if let number = Int(text) { defaults.set(number, forKey: key) }
        case .flag: defaults.set(text == "true", forKey: key)
        }
    }
}

/// The Settings list on this Mac. It applies incoming values to one `UserDefaults`, finds the keys whose values changed here, and gives the settings comparison its records and scope.
///
/// The controller calls `changedKeys()` on `UserDefaults.didChangeNotification` and runs the settings comparison when a key changed:
/// ```swift
/// let comparison = settings.comparison(mirror: mirror, pending: pending)
/// let changes = SyncDiff.changes(local: comparison.records, scope: comparison.contains, mirror: mirror, pending: pending, foundAt: Date())
/// ```
/// Its result replaces every pending `Setting` save, so a key it leaves out loses its pending save.
@MainActor
public final class SyncedSettings {
    /// The keys that sync, in the order of the note's Settings list.
    nonisolated public static let list: [SyncedSetting] = [
        SyncedSetting(key: "ARCHAppearance", values: .oneOf(["system", "light", "dark"])),
        SyncedSetting(key: "ARCHTintStrength", values: .oneOf(["subtle", "medium", "strong"])),
        SyncedSetting(key: "ARCHDefaultEngine", values: .oneOf(["webKit", "chromium"])),
        SyncedSetting(key: "ARCHSearchEngine", values: .oneOf(["google", "bing", "duckDuckGo"])),
        SyncedSetting(key: "ARCHArchiveAfterHours", values: .wholeNumber(0...168)),
        SyncedSetting(key: "ARCHUnloadAfterHours", values: .wholeNumber(0...168)),
        SyncedSetting(key: "ARCHOpensLinksInSmallWindow", values: .flag),
        SyncedSetting(key: "ARCHAskWhereToSaveDownloads", values: .flag),
    ]

    /// The listed setting for `key`, or nil for a key that stays on each Mac.
    nonisolated public static func setting(forKey key: String) -> SyncedSetting? {
        list.first { $0.key == key }
    }

    /// The records and scope of one settings comparison (`SyncDiff.changes(local:scope:mirror:pending:foundAt:)`).
    public struct Comparison: Hashable, Sendable {
        /// One record for each compared key, in list order, holding the value saved here, without edit times.
        public let records: [SyncRecord]
        private let keys: Set<String>

        init(records: [SyncRecord]) {
            self.records = records
            keys = Set(records.map(\.recordName))
        }

        /// Whether `record` is in the comparison's scope: a `Setting` record of a compared key. The scope lists only keys that `records` holds, so the comparison never deletes a `Setting` record.
        public func contains(_ record: SyncRecord) -> Bool {
            record.recordType == .setting && keys.contains(record.recordName)
        }
    }

    /// Called with the key after an incoming value is saved, so the app shell can apply what reads the key only at launch, such as the appearance (`NSApp.appearance`).
    public var onApplied: ((String) -> Void)?

    private let defaults: UserDefaults
    /// Each listed key's value as the last check found it or as last applied, by key; a key without a saved value is missing.
    private var checked: [String: String] = [:]
    /// Keys whose local value changed since their last refused value, or since launch. A key whose mirror value is not allowed here joins the comparison only then.
    private var changedHere: Set<String> = []

    /// Starts from the values saved in `defaults`, so the first check reports only later changes.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for setting in Self.list {
            checked[setting.key] = setting.text(in: defaults)
        }
    }

    /// Saves the value of an incoming `Setting` record when its key is listed and its `value` is allowed text, and returns whether it is. The record is a server record merged with this Mac's value (`SyncMerge`), so a refused value is later than every edit of the key here. It leaves the key's local value, and holds the key out of the comparison until that value changes here (`docs/sync.md`, Settings list).
    @discardableResult
    public func apply(_ record: SyncRecord) -> Bool {
        guard record.recordType == .setting, let setting = Self.setting(forKey: record.recordName) else { return false }
        let current = setting.text(in: defaults)
        guard case .text(let text)? = record[.value], setting.allows(text) else {
            // The refused value is newer than a local change that no check has found yet, so that change stays here too.
            checked[setting.key] = current
            changedHere.remove(setting.key)
            return false
        }
        // `UserDefaults` posts its change notification within `set`, so the value counts as checked first; otherwise the check would take it for an edit made here.
        checked[setting.key] = text
        guard current != text else { return true }
        setting.write(text, to: defaults)
        onApplied?(setting.key)
        return true
    }

    /// The listed keys whose values changed here since the last check, in list order. A value applied from a record is no change. Each key reported joins the comparison again if its mirror value was refused.
    public func changedKeys() -> [String] {
        var changed: [String] = []
        for setting in Self.list {
            let text = setting.text(in: defaults)
            if text != checked[setting.key] {
                checked[setting.key] = text
                changed.append(setting.key)
            }
        }
        changedHere.formUnion(changed)
        return changed
    }

    /// The settings comparison's records and scope: each listed key with an allowed value saved here, except a key whose mirror value is not allowed here, such as a value of a newer build. That key stays out, so its record keeps the other Mac's value, until its local value changes here; its pending save then keeps it in across launches until the save is sent, while the save's edit is later than the refused value's. Keys that only a newer build lists are never in scope.
    /// - Parameters:
    ///   - mirror: The mirror's records, as for `SyncDiff`.
    ///   - pending: Every save not sent yet.
    public func comparison(mirror: [SyncRecord], pending: [SyncRecord]) -> Comparison {
        let mirrorCopies = Dictionary(mirror.filter { $0.recordType == .setting }.map { ($0.recordName, $0) }) { first, _ in first }
        let pendingSaves = Dictionary(pending.filter { $0.recordType == .setting }.map { ($0.recordName, $0) }) { first, _ in first }
        var records: [SyncRecord] = []
        for setting in Self.list {
            let text = setting.text(in: defaults)
            if let copy = mirrorCopies[setting.key], !isAllowed(copy[.value], for: setting) {
                // A change that no check has found yet counts too, so the comparison does not depend on when the notification arrives. A pending save counts only when its edit is later than the refused value's, as after a relaunch; an earlier one lost the merge to that value.
                let laterSave = pendingSaves[setting.key].map { valueEditTime(of: $0) > valueEditTime(of: copy) } ?? false
                if !changedHere.contains(setting.key) && !laterSave && text == checked[setting.key] {
                    continue
                }
            }
            guard let text else { continue }
            records.append(SyncRecord(recordType: .setting, recordName: setting.key, fields: [SyncField.value.rawValue: .text(text)], modifiedAt: .distantPast))
        }
        return Comparison(records: records)
    }

    /// When `record`'s `value` was edited, as the merge reads it.
    private func valueEditTime(of record: SyncRecord) -> Date {
        record.fieldModifiedAt[SyncField.value.rawValue] ?? record.modifiedAt
    }

    private func isAllowed(_ value: SyncValue?, for setting: SyncedSetting) -> Bool {
        guard case .text(let text)? = value else { return false }
        return setting.allows(text)
    }
}
