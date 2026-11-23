// History window that lists one Persona's visited pages by day, searches them, and deletes single pages or a time range in that Persona or in every Persona.
import AppKit
import Combine
import SwiftUI

/// A Persona as the History window lists it: a surface without a space, so it names the Persona alone (`docs/windows-personas.md`, Persona rule 7).
public struct HistoryPersona: Hashable, Identifiable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Owns the History window of one store, which stays in memory when closed and reloads the store each time it becomes key. The window shows one Persona's pages, with a picker once there are two Personas. The store answers off the main thread, so the list fills in once the read is done. The app makes one for the session's store.
public final class HistoryWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {

    /// Opens a page from the window in a new browser tab of the shown Persona, which it passes.
    public var openURL: ((URL, UUID) -> Void)? {
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

    /// `personas` gives the session's Personas in their order, which the window reads each time it reloads.
    public init(store: HistoryStore, personas: @escaping () -> [HistoryPersona]) {
        let model = HistoryModel(store: store, personas: personas)
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryList(model: model)))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = localized("History")
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

    /// Brings the History window to the front with the Persona's current entries, as the History menu does for the active window's Persona. Becoming key loads them; a window that is key already, or that does not become key while the app is in the background, loads here. While the Clear History sheet shows, the window keeps the Persona that the sheet clears.
    public func show(persona: UUID) {
        if window?.attachedSheet == nil { model.persona = persona }
        if window?.isKeyWindow == true || !NSApp.isActive { model.reload() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Brings the History window to the front on the Persona and asks for a time range to clear, unless it shows that sheet already.
    public func showClearHistory(persona: UUID) {
        show(persona: persona)
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
            item.title = localized("Clear History\u{2026}")
            item.label = localized("Clear History")
            item.isBordered = true
            item.target = self
            item.action = #selector(chooseRangeToClear)
            return item
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = localized("Search History")
            item.searchField.target = self
            item.searchField.action = #selector(search(_:))
            searchToolbarItem = item
            return item
        default:
            return nil
        }
    }

    /// Clear History… waits for pages to clear. A search that shows none leaves it enabled, since it clears by time, and so do two Personas, since it can clear every Persona's.
    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier != Self.clearItem || model.hasEntries || model.personas.count > 1
    }

    @objc private func search(_ sender: NSSearchField) {
        model.query = sender.stringValue
    }

    /// Asks for a time range in a sheet, as the system's own browser does, and once there are two Personas also whether to clear the shown Persona's history or every Persona's, then clears it. The shown Persona comes first, so the default choice clears only what the window shows.
    @objc private func chooseRangeToClear() {
        guard let window else { return }
        let ranges = HistoryClearRange.allCases
        let rangeButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        rangeButton.addItems(withTitles: ranges.map(\.title))
        let persona = model.persona
        let alert = NSAlert()
        alert.messageText = localized("Clear History")
        if model.personas.count > 1 {
            let personaButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
            personaButton.addItems(withTitles: [localized("In \u{201C}\(model.personaName)\u{201D}"), localized("In Every Persona")])
            let stack = NSStackView(views: [rangeButton, personaButton])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.frame = NSRect(x: 0, y: 0, width: 220, height: 60)
            alert.accessoryView = stack
            alert.informativeText = localized("Clearing removes the pages last visited in this range from the History window and address suggestions, in the Persona you choose or in every Persona.")
            alert.addButton(withTitle: localized("Clear History"))
            alert.addButton(withTitle: localized("Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.model.clear(ranges[rangeButton.indexOfSelectedItem], in: personaButton.indexOfSelectedItem == 0 ? persona : nil)
            }
            return
        }
        alert.informativeText = localized("Clearing removes the pages last visited in this range from the History window and address suggestions.")
        alert.accessoryView = rangeButton
        alert.addButton(withTitle: localized("Clear History"))
        alert.addButton(withTitle: localized("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // With one Persona, the range clears every Persona's visits, those of Personas deleted since launch among them, whose removal waits for the next launch.
            self?.model.clear(ranges[rangeButton.indexOfSelectedItem], in: nil)
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
        case .lastHour: return localized("The Last Hour")
        case .today: return localized("Today")
        case .todayAndYesterday: return localized("Today and Yesterday")
        case .all: return localized("All History")
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

/// Holds every entry of the shown Persona and the filtered, grouped list the window shows.
private final class HistoryModel: ObservableObject {
    @Published private(set) var days: [HistoryDay] = []
    @Published var selection: Set<URL> = []
    /// The session's Personas as the last reload read them.
    @Published private(set) var personas: [HistoryPersona] = []
    /// The Persona whose pages the window shows. Choosing another one loads its pages.
    @Published var persona = UUID() {
        didSet {
            guard persona != oldValue else { return }
            selection = []
            entries = []
            regroup()
            reload()
        }
    }
    var query = "" {
        didSet { regroup() }
    }
    var openURL: ((URL, UUID) -> Void)?

    private let store: HistoryStore
    private let readPersonas: () -> [HistoryPersona]
    private var entries: [HistoryEntry] = []
    /// Counts reloads and deletions. A read's rows apply only while no later reload or deletion has come, so that an earlier read neither puts back rows a deletion removed nor replaces a later read's rows.
    private var generation = 0

    init(store: HistoryStore, personas: @escaping () -> [HistoryPersona]) {
        self.store = store
        readPersonas = personas
    }

    var personaName: String {
        personas.first { $0.id == persona }?.name ?? ""
    }

    /// Reads the Personas again, and the shown Persona's pages. A shown Persona that the user deleted gives way to the first one.
    func reload() {
        personas = readPersonas()
        if !personas.contains(where: { $0.id == persona }), let first = personas.first {
            // Setting the Persona reloads.
            return persona = first.id
        }
        generation += 1
        let generation = generation
        store.entries(since: .distantPast, in: persona) { [weak self] entries in
            guard let self, self.generation == generation else { return }
            self.entries = entries
            self.regroup()
        }
    }

    /// Opens the pages newest first, so the oldest ends up selected.
    func open(_ urls: Set<URL>) {
        ordered(urls).forEach { openURL?($0, persona) }
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
        store.remove(urls, in: persona)
        entries.removeAll { urls.contains($0.url) }
        regroup()
    }

    /// Clears the range in the Persona, or in every Persona for nil. The store runs its queries in order, so the reload sees the removal.
    func clear(_ range: HistoryClearRange, in persona: UUID?) {
        if let start = range.start(now: Date(), calendar: .current) {
            store.removeEntries(since: start, in: persona)
        } else {
            store.clear(persona: persona)
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

/// The History window's content: the Persona picker when there is more than one Persona, and the visits that match the search, by day.
private struct HistoryList: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            if model.personas.count > 1 {
                Picker(localized("Persona"), selection: $model.persona) {
                    ForEach(model.personas) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            list
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private var list: some View {
        Group {
            if model.days.isEmpty {
                Text(model.query.isEmpty ? localized("No History") : localized("No Results"))
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
                        Button(urls.count == 1 ? localized("Open in New Tab") : localized("Open in \(urls.count) New Tabs")) { model.open(urls) }
                        Button(urls.count == 1 ? localized("Copy Link") : localized("Copy Links")) { model.copy(urls) }
                        Divider()
                        Button(localized("Delete")) { model.delete(urls) }
                    }
                } primaryAction: { urls in
                    model.open(urls)
                }
                // Without a selection, Edit ▸ Delete and Copy have nothing to act on and stay disabled.
                .onDeleteCommand(perform: model.selection.isEmpty ? nil : { model.delete(model.selection) })
                .onCopyCommand(perform: model.selection.isEmpty ? nil : { model.copyItems(model.selection) })
            }
        }
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return localized("Today") }
        if calendar.isDateInYesterday(day) { return localized("Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}

/// One visit in the History window: its title or host, its address, and the time of its last visit.
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
