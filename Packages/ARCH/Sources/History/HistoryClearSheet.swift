// Clears a chosen time range and Persona scope in a sheet attached to the browser window.
import AppKit

/// A Persona offered by the history deletion sheet.
public struct HistoryPersona: Hashable, Identifiable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Presents history deletion without creating a separate browsing-history window.
@MainActor public enum HistoryClearSheet {
    public static func show(store: HistoryStore, persona: UUID, personas: [HistoryPersona], in window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let selectedPersona = personas.first { $0.id == persona } ?? personas.first
        let ranges = HistoryClearRange.allCases
        let rangeButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        rangeButton.addItems(withTitles: ranges.map(\.title))
        let alert = NSAlert()
        alert.messageText = localized("Clear History")
        let personaButton: NSPopUpButton?
        if personas.count > 1 {
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
            picker.addItems(withTitles: [localized("In \u{201C}\(selectedPersona?.name ?? "")\u{201D}"), localized("In Every Persona")])
            personaButton = picker
            let stack = NSStackView(views: [rangeButton, picker])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.frame = NSRect(x: 0, y: 0, width: 220, height: 60)
            alert.accessoryView = stack
            alert.informativeText = localized("Clearing removes the pages last visited in this range from browsing history and address suggestions, in the Persona you choose or in every Persona.")
        } else {
            personaButton = nil
            alert.accessoryView = rangeButton
            alert.informativeText = localized("Clearing removes the pages last visited in this range from browsing history and address suggestions.")
        }
        alert.addButton(withTitle: localized("Clear History"))
        alert.addButton(withTitle: localized("Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                  ranges.indices.contains(rangeButton.indexOfSelectedItem) else { return }
            // With one Persona, include visits from Personas deleted since launch, as the global command always has.
            let scope = personaButton?.indexOfSelectedItem == 0 ? selectedPersona?.id : nil
            let range = ranges[rangeButton.indexOfSelectedItem]
            if let start = range.start(now: Date(), calendar: .current) {
                store.removeEntries(since: start, in: scope)
            } else {
                store.clear(persona: scope)
            }
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
