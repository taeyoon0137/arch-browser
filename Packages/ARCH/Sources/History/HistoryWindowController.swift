// History window that lists visited pages by day, searches them, and deletes single pages or a time range.
import AppKit
import Combine
import SwiftUI

/// Owns the History window of one store, which stays in memory when closed and reloads the store each time it becomes key. The store answers off the main thread, so the list fills in once the read is done. The app makes one for the session's store.
public final class HistoryWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {

    /// Opens a page from the window in a new browser tab.
    public var openURL: ((URL) -> Void)? {
        get { model.openURL }
        set { model.openURL = newValue }
    }

    private let model: HistoryModel
    private static let clearItem = NSToolbarItem.Identifier("ARCHHistoryClear")
    private static let searchItem = NSToolbarItem.Identifier("ARCHHistorySearch")
    /// The toolbar's search field, which Edit ▸ Find… focuses.
    private weak var searchToolbarItem: NSSearchToolbarItem?
    /// Validates the toolbar again when rows arrive, which they do off any user event.
    private var daysSubscription: AnyCancellable?

    public init(store: HistoryStore) {
        let model = HistoryModel(store: store)
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryList(model: model)))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "History"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 560))
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "History")
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.center()
        // The model sets its entries before it publishes the days that follow from them.
        daysSubscription = model.$days.sink { [weak self] _ in self?.window?.toolbar?.validateVisibleItems() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    /// Brings the History window to the front with the store's current entries. Becoming key loads them; a window that is key already, or that does not become key while the app is in the background, loads here.
    public func show() {
        if window?.isKeyWindow == true || !NSApp.isActive { model.reload() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Brings the History window to the front and asks for a time range to clear, unless it shows that sheet already.
    public func showClearHistory() {
        show()
        if window?.attachedSheet == nil { chooseRangeToClear() }
    }

    /// Puts the cursor in the toolbar's search field, for Edit ▸ Find…, unless the Clear History sheet shows.
    public func focusSearch() {
        guard window?.attachedSheet == nil else { return }
        searchToolbarItem?.beginSearchInteraction()
    }

    // Pages visited in another window since the last look appear when the user returns here.
    public func windowDidBecomeKey(_ notification: Notification) {
        model.reload()
    }

    // MARK: Toolbar

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.clearItem, Self.searchItem]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.clearItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.title = "Clear History\u{2026}"
            item.label = "Clear History"
            item.isBordered = true
            item.target = self
            item.action = #selector(chooseRangeToClear)
            return item
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Search History"
            item.searchField.target = self
            item.searchField.action = #selector(search(_:))
            searchToolbarItem = item
            return item
        default:
            return nil
        }
    }

    /// Clear History… waits for pages to clear. A search that shows none leaves it enabled, since it clears by time.
    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier != Self.clearItem || model.hasEntries
    }

    @objc private func search(_ sender: NSSearchField) {
        model.query = sender.stringValue
    }

    /// Asks for a time range in a sheet, as the system's own browser does, then clears it.
    @objc private func chooseRangeToClear() {
        guard let window else { return }
        let ranges = HistoryClearRange.allCases
        let rangeButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        rangeButton.addItems(withTitles: ranges.map(\.title))
        let alert = NSAlert()
        alert.messageText = "Clear History"
        alert.informativeText = "Clearing removes the pages last visited in this range from the History window and address suggestions."
        alert.accessoryView = rangeButton
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.model.clear(ranges[rangeButton.indexOfSelectedItem])
        }
    }
}

/// A time range the user can clear, ending now.
private enum HistoryClearRange: CaseIterable {
    case lastHour
    case today
    case todayAndYesterday
    case all

    var title: String {
        switch self {
        case .lastHour: return "The Last Hour"
        case .today: return "Today"
        case .todayAndYesterday: return "Today and Yesterday"
        case .all: return "All History"
        }
    }

    /// The earliest last visit to remove, or `nil` for all history.
    func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .lastHour: return now.addingTimeInterval(-3600)
        case .today: return calendar.startOfDay(for: now)
        case .todayAndYesterday: return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case .all: return nil
        }
    }
}

/// The pages last visited on one day, newest first.
private struct HistoryDay: Identifiable {
    var id: Date { date }
    let date: Date
    var entries: [HistoryEntry]
}

/// Holds every entry in the store and the filtered, grouped list the window shows.
private final class HistoryModel: ObservableObject {
    @Published private(set) var days: [HistoryDay] = []
    @Published var selection: Set<URL> = []
    var query = "" {
        didSet { regroup() }
    }
    var openURL: ((URL) -> Void)?

    private let store: HistoryStore
    private var entries: [HistoryEntry] = []
    /// Counts reloads and deletions. A read's rows apply only while no later reload or deletion has come, so that an earlier read neither puts back rows a deletion removed nor replaces a later read's rows.
    private var generation = 0

    init(store: HistoryStore) {
        self.store = store
    }

    func reload() {
        generation += 1
        let generation = generation
        store.entries(since: .distantPast) { [weak self] entries in
            guard let self, self.generation == generation else { return }
            self.entries = entries
            self.regroup()
        }
    }

    /// Opens the pages newest first, so the oldest ends up selected.
    func open(_ urls: Set<URL>) {
        ordered(urls).forEach { openURL?($0) }
    }

    /// Whether the store has pages, whatever the search shows.
    var hasEntries: Bool { !entries.isEmpty }

    func copy(_ urls: Set<URL>) {
        let links = ordered(urls)
        guard !links.isEmpty else { return }
        let item = NSPasteboardItem()
        item.setString(links.map(\.absoluteString).joined(separator: "\n"), forType: .string)
        if links.count == 1 { item.setString(links[0].absoluteString, forType: .URL) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// What Edit ▸ Copy writes for the pages, the same as Copy Link: their addresses, one per line, and for one page its address as a URL too. SwiftUI writes the providers to the pasteboard.
    func copyItems(_ urls: Set<URL>) -> [NSItemProvider] {
        let links = ordered(urls)
        guard !links.isEmpty else { return [] }
        let provider = NSItemProvider(object: links.map(\.absoluteString).joined(separator: "\n") as NSString)
        if links.count == 1 { provider.registerObject(links[0] as NSURL, visibility: .all) }
        return [provider]
    }

    /// The rows leave the list at once; a read that started before the removal is dropped.
    func delete(_ urls: Set<URL>) {
        generation += 1
        store.remove(urls)
        entries.removeAll { urls.contains($0.url) }
        regroup()
    }

    /// The store runs its queries in order, so the reload sees the removal.
    func clear(_ range: HistoryClearRange) {
        if let start = range.start(now: Date(), calendar: .current) {
            store.removeEntries(since: start)
        } else {
            store.clear()
        }
        reload()
    }

    private func ordered(_ urls: Set<URL>) -> [URL] {
        entries.map(\.url).filter { urls.contains($0) }
    }

    /// Filters by title or address and groups by the day of each page's last visit. Rows hidden by the filter leave the selection, so Delete never removes a row the user cannot see.
    private func regroup() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = text.isEmpty ? entries : entries.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.url.absoluteString.localizedCaseInsensitiveContains(text) }
        let calendar = Calendar.current
        var grouped: [HistoryDay] = []
        for entry in matches {
            let day = calendar.startOfDay(for: entry.lastVisit)
            if grouped.last?.date == day {
                grouped[grouped.count - 1].entries.append(entry)
            } else {
                grouped.append(HistoryDay(date: day, entries: [entry]))
            }
        }
        days = grouped
        let visible = Set(matches.map(\.url))
        if !selection.isSubset(of: visible) { selection.formIntersection(visible) }
    }
}

private struct HistoryList: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        Group {
            if model.days.isEmpty {
                Text(model.query.isEmpty ? "No History" : "No Results")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.days) { day in
                        Section {
                            ForEach(day.entries) { HistoryRow(entry: $0) }
                        } header: {
                            Text(Self.title(for: day.date))
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: URL.self) { urls in
                    if !urls.isEmpty {
                        Button(urls.count == 1 ? "Open in New Tab" : "Open in \(urls.count) New Tabs") { model.open(urls) }
                        Button(urls.count == 1 ? "Copy Link" : "Copy Links") { model.copy(urls) }
                        Divider()
                        Button("Delete") { model.delete(urls) }
                    }
                } primaryAction: { urls in
                    model.open(urls)
                }
                // Without a selection, Edit ▸ Delete and Copy have nothing to act on and stay disabled.
                .onDeleteCommand(perform: model.selection.isEmpty ? nil : { model.delete(model.selection) })
                .onCopyCommand(perform: model.selection.isEmpty ? nil : { model.copyItems(model.selection) })
            }
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? entry.url.host ?? entry.url.absoluteString : entry.title)
                    .lineLimit(1)
                    .truncationMode(entry.title.isEmpty ? .middle : .tail)
                Text(entry.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text(entry.lastVisit.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .help(entry.url.absoluteString)
    }
}
