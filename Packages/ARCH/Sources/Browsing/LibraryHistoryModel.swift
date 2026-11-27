// Loads the library's history a page at a time from the current window's Persona.
import Combine
import Foundation
import History

enum LibraryTab: String, CaseIterable {
    case downloads
    case history

    static let defaultsKey = "ARCHLibraryTab"
}

/// Pages last visited on one calendar day, in the store's newest-first order.
struct LibraryHistoryDay: Identifiable {
    var id: Date { date }
    let date: Date
    var entries: [HistoryEntry]

    static func group(_ entries: [HistoryEntry], calendar: Calendar = .current) -> [Self] {
        var days: [Self] = []
        for entry in entries {
            let date = calendar.startOfDay(for: entry.lastVisit)
            if days.last?.date == date {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append(Self(date: date, entries: [entry]))
            }
        }
        return days
    }

    func title(relativeTo now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return localized("Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return localized("Yesterday")
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

enum LibraryHistoryClearRange: CaseIterable {
    case lastHour
    case today
    case all

    var title: String {
        switch self {
        case .lastHour: return localized("The Last Hour")
        case .today: return localized("Today")
        case .all: return localized("All History")
        }
    }

    func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .lastHour: return now.addingTimeInterval(-3600)
        case .today: return calendar.startOfDay(for: now)
        case .all: return nil
        }
    }
}

@MainActor final class LibraryHistoryModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    /// The top visible entry, retained while the sidebar changes between floating and docked hosts.
    @Published var scrollAnchor: URL?
    @Published var query = "" {
        didSet {
            if query != oldValue {
                scrollAnchor = nil
                reload()
            }
        }
    }

    let persona: UUID
    private let store: HistoryStore
    private let pageSize: Int
    private var generation = 0
    private var changes: AnyCancellable?
    private var reloadTask: Task<Void, Never>?

    init(store: HistoryStore, persona: UUID, pageSize: Int = 50) {
        self.store = store
        self.persona = persona
        self.pageSize = max(1, pageSize)
        changes = NotificationCenter.default.publisher(for: HistoryStore.didChange)
            .sink { [weak self, weak store] notification in
                guard let self, let store, notification.object as? HistoryStore === store,
                      notification.userInfo?["persona"] as? UUID == nil || notification.userInfo?["persona"] as? UUID == persona else { return }
                self.reload()
            }
    }

    var days: [LibraryHistoryDay] { LibraryHistoryDay.group(entries) }

    /// A query or store change invalidates pending page reads.
    func reload() {
        generation += 1
        reloadTask?.cancel()
        entries = []
        hasMore = true
        isLoading = false
        reloadTask = Task { [weak self] in await self?.loadNextPage() }
    }

    func loadNextPage() async {
        guard !isLoading, hasMore, !Task.isCancelled else { return }
        isLoading = true
        let generation = generation
        let page = await store.entries(in: persona, matching: query, limit: pageSize, before: entries.last)
        guard self.generation == generation else { return }
        isLoading = false
        guard !Task.isCancelled else { return }
        entries.append(contentsOf: page)
        hasMore = page.count == pageSize
    }

    func delete(_ entry: HistoryEntry) {
        store.remove([entry.url], in: persona)
        reload()
    }

    func clear(_ range: LibraryHistoryClearRange, now: Date = Date(), calendar: Calendar = .current) {
        if let start = range.start(now: now, calendar: calendar) {
            store.removeEntries(since: start, in: persona)
        } else {
            store.clear(persona: persona)
        }
        reload()
    }
}
