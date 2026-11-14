// Order keys: the `order` field that sorts a record among its siblings (`docs/sync.md`, Record types ▸ `order`, and Mapping the session store to records ▸ Order keys). The local arrays keep the order, and the keys live only in the records, so a move writes only the moved record and other Macs sort the same list the same way.
import Foundation

/// Which records share an order, how to sort them, and which keys a list of siblings gets after this Mac reorders it.
public enum SyncOrderKeys {
    /// A list of siblings that one sequence of order keys sorts: Personas among themselves, spaces and favorites within their Persona, folders within their parent folder or among their space's top-level pinned folders, and pinned tabs within their folder or among their space's pinned tabs outside folders. Folders and tabs keep separate lists because a list shows folders before tabs.
    public struct SiblingList: Hashable, Sendable {
        public var recordType: SyncRecordType
        /// The record name of the parent that holds the list, or nil for the Personas.
        public var parent: String?

        public init(recordType: SyncRecordType, parent: String?) {
            self.recordType = recordType
            self.parent = parent
        }

        /// The list that sorts `record`, or nil for a type without an order, such as a setting.
        public init?(of record: SyncRecord) {
            let parent: String?
            switch record.recordType {
            case .persona: parent = nil
            case .space, .favorite: parent = Self.reference(record[.persona])
            case .folder: parent = Self.reference(record[.parent]) ?? Self.reference(record[.space])
            case .tab: parent = Self.reference(record[.folder]) ?? Self.reference(record[.space])
            case .setting: return nil
            }
            self.recordType = record.recordType
            self.parent = parent
        }

        private static func reference(_ value: SyncValue?) -> String? {
            if case .reference(let name) = value { name } else { nil }
        }
    }

    /// The record's order key, or nil when it has none or an unusable one, such as an infinite number.
    public static func key(of record: SyncRecord) -> Double? {
        if case .number(let key) = record[.order], key.isFinite { key } else { nil }
    }

    /// Sorts siblings by order key, and records with equal keys by record name, so every Mac shows them in the same order. Records without a key sort after the others, by record name.
    public static func sorted(_ records: [SyncRecord]) -> [SyncRecord] {
        records.sorted { first, second in
            switch (key(of: first), key(of: second)) {
            case let (firstKey?, secondKey?) where firstKey != secondKey: firstKey < secondKey
            case (.some, nil): true
            case (nil, .some): false
            default: first.recordName < second.recordName
            }
        }
    }

    /// The order keys of one sibling list after this Mac has put `names` in this order, one for each name.
    ///
    /// `existing` holds the keys the siblings had before, by record name. The largest set of siblings whose keys are already in the list's order keeps its keys; equal keys count as in order when their record names are. Each other sibling gets a key between its nearest neighbors that keep theirs: the midpoint for one sibling between two, evenly spaced keys for several, and steps of 1 past either end of the list. When no `Double` fits between two neighbors, every sibling is renumbered 1, 2, 3, and so on.
    public static func keys(for names: [String], existing: [String: Double]) -> [Double] {
        let positions = names.map { name in existing[name].flatMap { $0.isFinite ? Position(key: $0, recordName: name) : nil } }
        let kept = longestIncreasingRun(positions)
        var result: [Double] = []
        var index = 0
        while index < names.count {
            if kept.contains(index), let position = positions[index] {
                result.append(position.key)
                index += 1
                continue
            }
            // The siblings from `index` up to the next kept one take keys between the kept neighbors.
            var end = index
            while end < names.count, !kept.contains(end) { end += 1 }
            let lower = index > 0 ? result.last : nil
            let upper = end < names.count ? positions[end]?.key : nil
            guard let gap = gapKeys(between: lower, and: upper, count: end - index) else {
                return names.indices.map { Double($0 + 1) }
            }
            result += gap
            index = end
        }
        return result
    }

    /// A sibling's place in its list: its key, then its record name for equal keys.
    private struct Position: Comparable {
        var key: Double
        var recordName: String

        static func < (first: Position, second: Position) -> Bool {
            (first.key, first.recordName) < (second.key, second.recordName)
        }
    }

    /// The indices of the longest subsequence of `positions` that is already in increasing order, skipping siblings without a key. Patience sorting finds it in O(n log n).
    private static func longestIncreasingRun(_ positions: [Position?]) -> Set<Int> {
        // `tails[length - 1]` is the index of the smallest last position of an increasing run of that length found so far.
        var tails: [Int] = []
        var previous = [Int?](repeating: nil, count: positions.count)
        for (index, position) in positions.enumerated() {
            guard let position else { continue }
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if let tail = positions[tails[middle]], tail < position { low = middle + 1 } else { high = middle }
            }
            previous[index] = low > 0 ? tails[low - 1] : nil
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run = Set<Int>()
        var index = tails.last
        while let current = index {
            run.insert(current)
            index = previous[current]
        }
        return run
    }

    /// `count` increasing keys strictly between `lower` and `upper`, either of which may be missing, or nil when no `Double` fits.
    private static func gapKeys(between lower: Double?, and upper: Double?, count: Int) -> [Double]? {
        let keys: [Double] = (0..<count).map { offset in
            switch (lower, upper) {
            case let (lower?, upper?): lower + (upper - lower) * Double(offset + 1) / Double(count + 1)
            case let (lower?, nil): lower + Double(offset + 1)
            case let (nil, upper?): upper - Double(count - offset)
            case (nil, nil): Double(offset + 1)
            }
        }
        var previous = lower
        for key in keys {
            guard key.isFinite, previous.map({ $0 < key }) ?? true else { return nil }
            previous = key
        }
        if let upper, let last = keys.last, last >= upper { return nil }
        return keys
    }
}
